# Plan: no double order on a deploy, one order at a time per supplier account (Oct 20 2026)

Status: **APPROVED by Carmin Oct 20 2026, as written, including skipping cancelled orders. Built: see `docs/order-placement-double-submit-and-account-lock.md` for what changed, what didn't work, and the open items.**

The Oct 20 2026 scaling review ranked two gaps in `PlaceOrderJob` among the fixes needed before growth (7 locations today, about 250 restaurants / 1,000 users ahead). Today the only guard against gap 1 is pushing only while the worker is idle. That stops working once orders arrive all day.

1. **A deploy mid-order can submit the same order twice.**
2. **Two orders on one supplier account can run at once and share one supplier cart.**

Both are re-verified below against the code and the installed Solid Queue 0.9.0 gem. Gap 2 turns out to be *partly* covered already (see "What already protects us"), but not for the cases that grow with volume.

---

## 1. Gap 1: how a deploy re-runs an order

Verified in `solid_queue-0.9.0`:

- On SIGTERM the worker stops taking jobs and waits `SolidQueue.shutdown_timeout` (default **5 s**) for running jobs (`Worker#shutdown` → `pool.wait_for_termination`).
- It then deregisters. `Process#destroy!` → `after_destroy :release_all_claimed_executions` → `ClaimedExecution#release` → `job.dispatch_bypassing_concurrency_limits`. The still-running `PlaceOrderJob` goes **back on the queue as ready**, ignoring our `limits_concurrency` semaphore. The process then exits and its order thread dies wherever it was.
- The new worker picks the job up and runs `perform` again from the top.
- `PlaceOrderJob` skips only `Order#completed?` (submitted / confirmed / dry_run_complete). The only "submit already sent" record is `@submit_sent` in the dead process's memory. So if the first run died **after the live submit request went out but before we wrote `submitted`**, the second run clears the cart, rebuilds it and submits again.

If the process is SIGKILLed instead (no graceful deregister), Solid Queue prunes it after 5 min and marks the job *failed* (`ProcessPrunedError`); it is not re-run automatically. The order stays `processing`, and after 15 min the red "needs attention" bar shows it (`Order::STUCK_PROCESSING_AFTER`). A retry from Mission Control (`/jobs`) would then re-run it and has the same double-order hole.

### What each supplier does on a re-run after a live submit

All six were read (the `*_scraper.rb` `clear_cart` / `add_to_cart` / `verify_cart_matches!` / `checkout`, plus the `*_api.rb` submit calls). **Nothing in our code or the supplier APIs stops a second order at any of them.** No submit carries an idempotency key or a PO number we could check.

| Supplier | Cart the order is built in | Live submit (after `submit_sent!`) | Re-run after a live submit | Read-back that could settle "did it go through?" |
|---|---|---|---|---|
| **US Foods** | The IN_PROGRESS order(s) of the customer the token points at. `clear_cart` empties **every** IN_PROGRESS order; `get_or_create_order` reuses one for the date, else re-dates **any** IN_PROGRESS order (`us_foods_api.rb:395-426`). | `submitIpOrder` POST with the verified copy (`us_foods_scraper.rb:2273`) | The placed order is no longer IN_PROGRESS, so a new cart is created and submitted: **second order**. | `fetch_submitted_order` (recentorders, by orderId or tandem number). The orderId is known before submit. |
| **Sysco** | A per-run draft (`createOrderV2` with a fresh random `idempotencyToken`), but `clear_cart` deletes **every** OPEN WEB draft on the shop account. | `submitOrderV2` (`sysco_scraper.rb:902`) | New draft, new token, submitted: **second order**. | Open-orders headers by draft id (`sysco_lists_submitted?`). The confirmation number is a minute-resolution name, not unique. |
| **Chef's Warehouse** | One server-side cart per login + selected organization; `cart/submit` sends the whole cart (`chefs_warehouse_api.rb:432`). | `cart/submit` (`chefs_warehouse_scraper.rb:647`) | The first submit emptied the cart, so `clear_cart` passes and a fresh cart is submitted: **second order**. | None by id. `order_history_details` exists, is unused, and its shape is unverified. |
| **What Chefs Want** | A per-run draft (`CreateOrUpdateDraftMutation`, `draftId: nil`); the company selection is session-wide. | `CreateNewOrderMutation` with `duplicateIsOk: false` (`what_chefs_want_scraper.rb:301`) | A new draft is submitted. **Unverified** whether `duplicateIsOk: false` makes WCW refuse it. Assume a **second order**. | `get_orders` by date (heuristic match only). |
| **Premiere Produce One** | One draft per **restaurant** + supplier, not per user. `clear_cart` zeroes every DRAFT/IN_REVIEW order; `add_to_cart` uses the first open order (`premiere_produce_one_scraper.rb:250`). | `submitOrder` (`premiere_produce_one_scraper.rb:485`) | The placed order left DRAFT, so a new draft is created and submitted: **second order**. | `get_order_status(uuid)` + `placed_at`: the best of the six. |
| **Performance** | One active draft per customer (`GetActiveOrder`); `clear_cart` deletes it. | `SubmitOrderEntryHeader` (`performance_scraper.rb:501`) | A new draft is created and submitted: **second order**. | `get_order(oeh)['OrderNumber']`. |

In every scraper, `submit_sent!` sits right before the submit request, outside the `begin/rescue` around it, and only on the live path (each dry-run return comes first). So a hook there that raises stops the order cleanly, before anything is sent.

---

## 2. Gap 2: two orders on one supplier account

### What already protects us

`Suppliers::RestaurantSwitcher#enter` takes `pg_advisory_lock(72310, credential.id)` and holds it until `leave`, which is the whole clear → add → verify → submit span. So **two orders on Alfio's matched multi-restaurant logins (USF, CW, WCW, PPO) are already serialized** today. The review's wording ("two of those restaurants can order at the same moment") is too strong for those logins.

### What is still open

- **Only logins with restaurant matches take that lock.** Every other login (every chef) takes none.
- **It is keyed on the credential row, not on the cart.** Carts are shared more widely than one credential row:
  - **Two logins at one restaurant.** PPO keeps one draft per restaurant, and US Foods empties every IN_PROGRESS order for the customer. One run's clear can wipe the other's lines, and one run's submit can ship the other's lines.
  - **One login on several credential rows.** The unique index is user + supplier + location (Alfio's PPO #73 and #136).
  - **One chef, two orders for the same supplier at once.** For example, two lists submitted seconds apart. US Foods' clear empties the other order's cart, and `get_or_create_order` can re-date it.
  - Most of these fail closed today at `verify_cart_matches!`. But the window between verify and submit is open: CW's `cart/submit` and PPO's `submitOrder` send whatever is in the shared cart at that moment.
- **It blocks the worker thread with no time limit.** It uses `pg_advisory_lock`, not a try. The critical queue has **2 threads in total** (`config/queue.yml`), so two orders waiting on one account would stall order placement for every restaurant.
- **It is taken after pre-order validation,** which also logs in and refreshes the session (and US Foods persists the auth context on refresh).
- **A deploy re-run (gap 1) and the dying first run can overlap briefly.** The re-run is queued just before the old process exits.

`limits_concurrency` (keyed `place_order_<order_id>`) only serializes re-attempts of the same order, and Solid Queue bypasses it on release.

---

## 3. Options considered

### Persisted "submit sent" marker

| Option | Verdict |
|---|---|
| **A. `orders.submit_sent_at` column, written and committed right before the live submit request** (from `submit_sent!` through a hook the placement service installs). A run that finds it set never submits. | **Recommended.** It sits on the exact line every scraper already marks, needs one nullable column, and does not change which statuses the app knows. |
| B. A new order status `submitting`. | Rejected. Statuses are matched all over the app (views, filters, the attention bar, `retryable?`, KPIs, batch progress). A wide blast radius for a marker. |
| C. A separate `order_submit_attempts` table (one row per attempt). | Not now. Better history, more moving parts. Can come later if we add automatic read-back. |
| D. Detect a re-run from Solid Queue internals (claimed/released executions). | Rejected. It can't tell "died before submit" (safe to re-run) from "died after submit", and it depends on gem internals. |
| E. Supplier-side de-duplication (PO number = EnPlace order id, check recent orders before submitting). | Not now. It needs recorded proof per supplier (no guessed calls), and only some suppliers can look orders up. A good later step: see open items. |
| F. A longer `SolidQueue.shutdown_timeout` so in-flight orders finish during a deploy. | Not a fix: Railway still kills the container at its own deadline, and an order with a sign-in wait can take minutes. Possibly a later complement. |

### One order at a time per supplier account

| Option | Verdict |
|---|---|
| **A. Postgres session advisory locks, non-blocking (`pg_try_advisory_lock`), taken by `PlaceOrderJob` before anything touches the supplier.** If busy, the job re-queues itself 20 s later and frees its thread. | **Recommended.** Postgres drops the lock the instant a worker process dies, so there is no stale lock after a kill. It works across processes and containers, and never ties up one of the two critical threads. |
| B. Change `limits_concurrency` to an account key. | Rejected as the guarantee. Solid Queue bypasses it on release (gap 1 itself). It expires after `duration`, and after a SIGKILL the semaphore stays held up to ~25 min, blocking the whole account. The key is also computed at enqueue, before the login is chosen. |
| C. Blocking `pg_advisory_lock` (like the switcher). | Rejected. It has no time limit and stalls the 2 critical threads. |
| D. A row lock (`with_lock`) or a transaction around placement. | Rejected. It would hold a transaction open for minutes, block session saves and `RefreshSessionJob`, and roll the marker back on a crash. |

### Which keys the lock takes

Two keys per order, both from local data (no supplier calls), taken all-or-nothing:

- **Restaurant at the supplier:** `supplier_id + order.location_id`. This covers two logins at one restaurant (PPO per-restaurant draft, US Foods per-customer carts) and one chef's two orders.
- **The supplier login:** `supplier_id + the login's username`, lowercased. This covers one login serving several restaurants (Alfio) and one login on several credential rows.

A key that over-serializes is safe. For example, Alfio's three separate Performance logins don't share a cart, but his orders would run one after another.

---

## 4. Recommended approach

### 4.1 `Orders::SupplierAccountLock` (new, small)

- `SupplierAccountLock.for(order)` builds the two keys. The login comes from the same `Suppliers::OrderCredential.scope(order)` query the placement service uses. Each key is `pg_try_advisory_lock(72_311, crc32(key))`, beside the switcher's 72_310. A hash collision only adds waiting.
- `acquire`: tries both keys in a fixed order. If either is busy, it releases what it took and returns false. It never waits, so it can't deadlock with the switcher lock, which is always taken after it.
- `held?`: reads `pg_locks` for this connection. It is checked again right before the submit (4.3), because Rails 7.1 can silently reconnect a dropped connection, and a reconnect drops session locks.
- `release`: unlocks in `ensure`, and logs loudly if the lock was already gone.

### 4.2 `PlaceOrderJob#perform`

1. Unchanged up front: the `completed?` skip and demo mode.
2. Acquire the account lock. **If busy:** re-queue the same job with `wait: 20.seconds`, recording when the wait began. After 10 min of waiting (below the 15 min attention-bar threshold), give up: `failed` with "Not placed. Another *Supplier* order for this restaurant or login was still going through, so nothing was sent. Try again in a few minutes." The usual not-placed alert follows. Nothing has touched the supplier at that point.
3. **Under the lock, reload the order and check it again**: whoever held the lock may just have placed, cancelled or sent it.
   - `completed?` → skip (as today).
   - `cancelled?` → skip. **This is new (found in passing):** today a chef can cancel a queued order (`can_cancel?` allows `processing`, and batch orders wait 15 s each), and the job places it anyway.
   - `submit_sent_at` present → **never submit again.** If the order is still `processing` (an interrupted run), set `pending_manual` with the existing "We sent this order to *X*, then something went wrong before it confirmed… Check *X* before reordering" message, and send the existing *unconfirmed* email to the chef and owner(s). That is Carmin's rule for "looked placed, then something inconsistent". Any other status (an unconfirmed `pending_manual`, a refused `failed`) is left exactly as it is.
4. Then the existing placement runs. The lock covers pre-order validation too, so session refreshes on that login can't interleave either.
5. `record_crash` also treats a persisted `submit_sent_at` as "may have gone through" (→ `pending_manual`, never `failed`).

### 4.3 The marker

- `BaseScraper` gets `attr_writer :before_live_submit`. `submit_sent!` calls it **first**, then sets `@submit_sent`.
- `OrderPlacementService` installs the hook when it builds the scraper. The hook:
  1. confirms the account lock is still held;
  2. writes `order.update_columns(submit_sent_at: Time.current)`, a single autocommitted UPDATE.
- If either step fails, the hook raises before the submit request is sent. The order fails with the usual "Not placed… nothing was ordered" message: fail closed.
- `Order#start_placement!` (the chef's Submit, batch submit, accept-price-changes) clears `submit_sent_at`. A new attempt the chef chose deliberately, from a state that means nothing was placed (`pending`, `pending_review`, `price_changed`, `draft`), starts clean. `pending_manual` can't be resubmitted from the app, so an unconfirmed order stays guarded.
- Dev and test always dry-run, and no scraper calls `submit_sent!` on a dry run. **The marker is written only for live production orders.**

### 4.4 Migration safety

One migration: `add_column :orders, :submit_sent_at, :datetime` (nullable, no default, no backfill).

There is a known hazard: the worker can boot before web runs the migration and keep a stale column list, which raises `UnknownAttributeError` (see the memory note "restart worker after migration deploys"). The code checks once per process whether the column exists. If it doesn't, it logs an error and behaves exactly as today rather than failing every order. **After the deploy, restart the worker once, while it is idle**, per the existing procedure.

### 4.5 Who this changes things for

**Every order, not only multi-restaurant owners.** Gap 1 and the same-restaurant cases apply to every chef.

- A single-location chef's order now takes two advisory locks in the job (the placement service itself is untouched, so `single_location_chef_unchanged_spec` stays true).
- A second order on the same restaurant + supplier, or the same login, waits up to 10 min in 20 s steps instead of running alongside.

---

## 5. Tests (regression specs that fail on today's code)

- **Gap 1 repro.** A fake scraper whose checkout calls `submit_sent!` and then "dies" (an `Exception` that escapes every rescue, like a killed thread). The order stays `processing` with `submit_sent_at` set. Run `PlaceOrderJob.perform_now` again (the released re-run): **no second checkout or submit**, the order becomes `pending_manual`, and the unconfirmed alert is scheduled. Today the second run submits again.
- **Gap 2 repro, against real Postgres locks.** Hold the account lock from a *second database connection* (another order mid-placement):
  - The same restaurant + supplier through a different login is blocked: no supplier call, the job is re-queued 20 s later, and the order is still `processing`.
  - The same login for another restaurant (Alfio) is blocked.
  - A different restaurant on a different login proceeds.
  - After release, the re-queued job places the order.
- After 10 min of waiting: `failed` with "nothing was sent", and the alert is scheduled.
- A cancelled order is never placed. A `failed` or `pending_manual` order with the marker is left untouched.
- Marker hook:
  - It writes before the submit.
  - If the write raises, or the lock is gone, no submit happens and the order fails "not placed".
  - `start_placement!` clears it.
  - `record_crash` uses the persisted marker.
- The full `bundle exec rspec` suite runs on a separate test database for this branch (the migration would thrash the shared one).

## 6. What this does NOT fix (open items)

- **No automatic "did it go through?" read-back.** An interrupted-after-submit order goes to `pending_manual`, and the chef checks the supplier. PPO (`get_order_status`), Performance (`get_order`), US Foods (recent orders) and Sysco (headers by id) could settle it automatically if we also save the supplier's cart/draft id before submit. Proposed as a later phase, after this ships.
- **Supplier-side de-dupe via PO number** (US Foods `purchaseOrderNumber`, Sysco `poNumber`, PPO `po_number`, WCW `PONumber`, CW `set_po_number`). These are all unused today and would need recorded proof per supplier.
- **A cancel that lands while the job is already mid-flow** still doesn't stop it (the job's final write wins). The new check stops only queued or waiting jobs.
- **The 2-thread critical queue** caps the whole platform at two orders being placed at once. That is a scaling item of its own, separate from correctness.
- **Syncs and price checks** take only the switcher lock (matched logins). They don't touch carts as far as I can see by name, but an order can still wait on the switcher lock behind a long list sync (as today).
- **Other cart-touching paths.** The 2FA "resume checkout" in `two_factor_channel.rb` is dead code (nothing creates a `checkout` 2FA request). If it were ever revived, the new under-lock checks would guard it.
- **Pathological overlap.** A run of the same order that is still alive somewhere after 10 min (a hung zombie process) could race the "gave up waiting" write. Not seen; noted.

## 7. Rollout

1. Approve this plan. Then implement, write the specs, and get the full suite green on a branch test DB.
2. Carmin approves the commit, and separately the push.
3. Push with the worker idle (today's rule applies one last time), then restart the worker once after web has migrated.
4. Watch the first orders: `[PlaceOrderJob]` logs for the lock (acquired, waiting, released) and the marker writes.
