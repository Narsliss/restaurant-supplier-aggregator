# Order placement: no double order on a deploy, one order at a time per supplier account (Oct 20 2026)

Status: **BUILT on branch `claude/reverent-newton-54aa4b`. Not committed, pushed or deployed.**

The plan Carmin approved on Oct 20 2026 (including the new skip for cancelled orders) is in `docs/plan-order-placement-double-submit-and-account-lock.md`. It has the per-supplier analysis and the options that were turned down. This file records what was built.

## Why

The Oct 20 scaling review found two gaps in `PlaceOrderJob`. Both were re-verified before any code was written:

1. **A deploy mid-order could submit the same order twice.**
   - When the worker shuts down, Solid Queue 0.9.0 waits 5 s, then puts the running job back on the queue (`ClaimedExecution#release` → `dispatch_bypassing_concurrency_limits`).
   - The job only skipped `completed?` orders, and "submit already sent" lived only in memory (`@submit_sent`).
   - So if the first run died after the supplier took the order but before we wrote `submitted`, the re-run cleared the cart, rebuilt it and submitted again.
   - All six suppliers would take that second order: none of their submit calls carries an idempotency key or PO number.
   - The only guard was pushing while the worker was idle, and that stops working once orders arrive all day.
2. **Two orders on one supplier account could run at once.**
   - `RestaurantSwitcher`'s lock already serialized Alfio's *matched* logins. But it is keyed on the connection row, is taken only for matched logins, and blocks one of only 2 critical threads with no time limit.
   - Nothing stopped two logins at one restaurant from overlapping (Premiere Produce keeps one draft per restaurant; US Foods empties every open order of the customer).
   - Nothing stopped one chef's two orders to the same supplier from overlapping.

## What changed

| File | Change |
|---|---|
| `db/migrate/20261020180000_add_submit_sent_at_to_orders.rb` | `orders.submit_sent_at` (datetime, nullable, no backfill). |
| `app/services/scrapers/base_scraper.rb` | `attr_writer :before_live_submit`. `submit_sent!` calls it **first**, then sets `@submit_sent`. Every scraper already calls `submit_sent!` right before its live submit request, outside the rescue around it and after its dry-run return, so no scraper file changed. |
| `app/services/orders/order_placement_service.rb` | `new(order, account_lock: nil)`. It installs the hook on the scraper. `record_live_submit!` re-checks that the account lock is still held, then commits `update_columns(submit_sent_at: now)`. If either fails, it raises before the request: the order fails "Not placed… nothing was ordered / nothing was sent". |
| `app/services/orders/supplier_account_lock.rb` (new) | Two Postgres session advisory locks per order, in namespace 72_311 (the switcher uses 72_310): `restaurant:<supplier>:<location>` and `login:<supplier>:<username, lowercased>`. Taken with `pg_try_advisory_lock`, all or none, in a fixed order; never waits. Also `held?` (reads `pg_locks` for this connection) and `release`. Every query bypasses the query cache. |
| `app/jobs/place_order_job.rb` | Acquires the lock before anything touches the supplier, pre-order checks included. If the account is busy, it re-queues itself 20 s later with `account_wait_since`, which frees the thread. After 10 min it stops: `failed` with "Another *X* order for this restaurant or login was still going through, so nothing was sent", plus the not-placed alert. Under the lock it reloads the order and runs `still_to_place?`: completed or **cancelled** → skip; `submit_sent_at` set and still `processing` → `pending_manual` with the existing "may or may not have gone through, check *X*" text and the *unconfirmed* email to the chef and owner(s); `submit_sent_at` set in any other status → left as is. The lock is released in the method's `ensure`, after `record_crash`. |
| `app/jobs/place_order_job.rb` (`record_crash`) | A saved marker counts as "may have gone through", the same as the in-memory flag. An order sent and settled by an *earlier* run is never rewritten by this run's crash. |
| `app/models/order.rb` | `start_placement!`, the chef's deliberate new attempt, clears `submit_sent_at`. New `submit_sent_recorded?`, and `Order.submit_marker?` for the column check described under the deploy steps. |

What the chef sees:
- **Usually nothing changes.**
- A second order on the same restaurant + supplier, or the same login, now waits (still shows as submitting) instead of running alongside.
- A cancelled order that was still queued is no longer placed.
- An order cut off right after its submit lands in "needs manual check" with the existing email, never "failed" (failed would invite a second order).

## Specs

Every new behaviour has a spec:

- **`spec/jobs/place_order_job_account_safety_spec.rb` (new).** It drives the real job and placement service against a `BaseScraper` subclass that records each supplier step, with production's live path on. A `SimulatedWorkerKill < Exception` escapes every rescue, like a killed thread.
  - **Gap 1 repro:** kill right after the submit, then run the job again (the copy Solid Queue re-queues). It submits **once** and lands in `pending_manual` with the unconfirmed alert. On the old code this example fails with `expected: 1, got: 2`: the double order.
  - Also covered: the marker is committed before the request; a kill before the submit still places normally on re-run; refused and unconfirmed orders are left alone; a chef's new attempt clears the marker and places; a failed marker write sends nothing; a cancelled queued order is never placed.
  - **Gap 2 repro, with real Postgres locks held by another connection:**
    - another chef's login at the same restaurant → waits (no supplier call, re-queued with `account_wait_since`);
    - the owner's same login for another restaurant → waits;
    - one login on two connection rows (case and spaces differ) → waits;
    - a different restaurant on a different login → runs alongside;
    - a later try after release → placed;
    - waiting 11 min → failed "nothing was sent", alert, no re-queue;
    - the lock is released after success and after a kill;
    - lock lost before the submit (`pg_advisory_unlock_all` on the job's connection, standing in for a silent reconnect) → nothing sent, "lost its hold".
  - On the old code, 13 of the 16 fail. The 3 that pass are the controls.
- **`spec/services/orders/supplier_account_lock_spec.rb` (new):** key names; all-or-none; another supplier is unaffected; `held?` after a lost lock; and the query-cache trap below.
- **`spec/models/order_spec.rb`:** the marker is cleared and kept correctly; the missing-column fallback.
- **`spec/services/scrapers/base_scraper_spec.rb`:** the hook runs first, and a failing hook means nothing counts as sent.
- **`spec/jobs/place_order_job_spec.rb`:** `record_crash` uses the saved marker; an earlier run's outcome survives a crash; the service is built with the lock.

The full suite runs on the branch's own test DB (`restaurant_supplier_aggregator_test_ordersafety`), because the migration would thrash the shared one. Result: see the bottom of this file.

## What did NOT work / traps found

- **The query cache answered lock calls from memory.** The first version used `select_value("SELECT pg_try_advisory_lock(...)")`. In a `rails runner` smoke test, the second lock attempt and the unlock came back `CACHE` and never reached Postgres: an unlock reported success while the lock stayed held. Jobs run inside the Rails executor with the query cache on, so this would have broken the lock in production. Every lock query now goes through `connection.uncached`. `RestaurantSwitcher` is unaffected because it uses `execute`, which skips the cache. A spec guards this.
- **Spec threads can't stand in for another worker.** Transactional tests pin every thread to one connection (`lock_threads`), and session advisory locks are re-entrant on one session. So "another placement" checks out its own pool connection, and `acquire` takes `connection:` for that.
- **The first job version released the lock in an inner `ensure`,** before the outer rescue's `record_crash` ran. Another run of the order could then start before the crash was written down. The release now sits in the method's own `ensure`.
- **`record_crash` and earlier runs.** Without the new early return, a crash during this run's first reload would rewrite an earlier run's unconfirmed or refused outcome.

## Deploy steps (when Carmin approves the push)

1. Push while the worker is idle. Today's rule applies one last time: the running worker has the old code.
2. Web runs the migration on boot. The worker may have booted first and kept a column list without `submit_sent_at`. In that case `Order.submit_marker?` is false: it logs `[Order] orders.submit_sent_at is missing from this process's columns: restart it` and behaves as before the marker (lock on, marker off) rather than failing every order.
3. **Restart the worker once after web has migrated**, while it is idle (`railway redeploy --service worker --yes`, then verify). From then on the marker is live.
4. Watch the first orders' `[PlaceOrderJob]` and `[SupplierAccountLock]` log lines. An error that the lock "was no longer held when released" means a connection dropped mid-order: worth a look.

The local dev DB already has the column (migrated during this work). If the branch is dropped, run `bin/rails db:rollback` there.

## Open items

- **No automatic "did it go through?" read-back.** An interrupted order goes to `pending_manual` and the chef checks the supplier. PPO (`get_order_status`), Performance (`get_order`), US Foods (recent orders) and Sysco (headers by draft id) could settle it automatically if we also saved the supplier's cart/draft id before submit. A later phase.
- **Supplier-side de-dupe via PO number** (all unused today). It needs recorded proof per supplier: no guessed calls.
- **A cancel during a placement already in progress** still doesn't stop it. Only queued or waiting jobs see the cancel.
- **The login key follows `OrderCredential.scope(order).take`,** the same query placement uses. If a user ever had two *different* active logins serving one restaurant for one supplier, the lock and placement could pick different rows. The restaurant key still serializes them.
- **Two EnPlace locations sharing one supplier account** (one ship-to) would not be serialized by the restaurant key. Not seen today.
- **The critical queue has 2 threads,** which caps the platform at two placements at once. Waiting orders no longer hold a thread, but this is its own scaling item.
- **List syncs and price checks** take only the switcher lock. An order can still wait behind a long sync on the switcher's blocking lock, as before.
- **If a run of the same order hangs for more than 10 min** in a zombie process, it could race the "gave up waiting" write. Not seen.
- **A longer `SolidQueue.shutdown_timeout`** (most in-flight orders would finish during a deploy) depends on Railway's drain window. Not changed.

## Test results

Oct 20 2026, full `bundle exec rspec` on `restaurant_supplier_aggregator_test_ordersafety`: **2,106 examples, 0 failures.**

The first full run had 250 request-spec failures, all from one missing file: `stylesheet_link_tag "tailwind"`. This fresh worktree had no compiled `app/assets/builds/tailwind.css`, which is git-ignored. After `bin/rails tailwindcss:build` the suite ran clean. Nothing in this change was involved.

Before writing the fix, the new account-safety spec was also run against the old app code (the specs and migration kept, the four app files reverted). 13 of its 16 examples failed, including the double submit, `expected: 1, got: 2`.
