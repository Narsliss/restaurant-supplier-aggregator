# Plan: a demo site that never talks to a supplier

**Status:** approved Oct 20 ("build the local branch for me to test on a local server"). Built and tested locally, not committed or deployed. See the record: [demo-site-offline-suppliers.md](demo-site-offline-suppliers.md).
**Date:** 2026-10-20
**Branch:** `demo` (this file lives only there)
**Demo:** https://demo-web-production-6232.up.railway.app (Railway project "SupplierHub Demo": `demo-web` + Postgres, no worker)

## Why

Customers are starting to buy, and the sales demo shows errors:

- Supplier Credentials: US Foods, PPO and What Chefs Want show red "Disconnected" and "Session expired. Click Validate…". Sysco shows "Catalog sync pending".
- Bella Vista Downtown matched list: stuck on "Processing — please wait" forever.

### Root cause (verified in code, Oct 20)

The demo runs `RAILS_ENV=production` with **no worker**, and Puma only runs background jobs outside production (`config/puma.rb`: `plugin :solid_queue unless … 'production'`). So on the demo **every background job is queued and never runs**:

- **Matching:** clicking anything that matches (run matching, sync new products, add a supplier guide, catalog search) sets the list to "matching" and queues a job. The job never runs, so the spinner never clears.
- **"Disconnected":** a 2FA/welcome-URL login counts as connected only if it has a saved session less than 24 hours old (`SupplierCredential#session_valid?`). The demo's sessions were scrubbed, and nothing can refresh them.
- **"Catalog sync pending":** no product of that supplier has a "last scraped" time.

### Today's safety position (verified Oct 20)

The demo cannot place a real order today, but by luck rather than design:

- Orders are submitted through `PlaceOrderJob`, which never runs on the demo. It also fakes the submit in demo mode.
- The image has no Chromium (`INSTALL_CHROMIUM=false`).
- There's no mail key, so no email can go out.
- On every boot, `seed_suppliers` sets `checkout_enabled = true` on the demo, because it's `RAILS_ENV=production`.
- One web request does contact suppliers synchronously, over plain HTTP: the "restaurants on this login" page (`SupplierCredentialsController#restaurants` / `#update_restaurants`).
- **Not yet verified:** whether real supplier credentials survive in the demo database. The Aug 13 reseed tool isn't in git. A read-only probe that prints only counts is ready and waiting for Carmin to run it.

## The three walls that keep demo code out of production

Carmin's main concern: nothing on the `demo` branch may reach `main` or production.

1. **Separate deploy.** `demo-web` is switched to build from the `demo` branch. Production keeps building from `main`.
   - Pushing `demo` deploys only the demo. Pushing `main` stops redeploying the demo.
   - Before the switch, a read-only check confirms that production's two services build only from `main`. That check needs Carmin's OK at the time.
2. **One-way merges, enforced.**
   - Changes only ever flow `main → demo`.
   - A git `pre-push` hook on this Mac covers every Claude session and Carmin's terminal. It refuses any push to `main` that contains the `demo/` folder or any commit unique to the `demo` branch.
   - A memory rule tells future Claude sessions the same.
   - Optional extra: a GitHub rule on `main`. That's a repo-settings change, so it's Carmin's call.
3. **Inert even if it leaked.**
   - All demo code lives in one new top-level folder, `demo/`. It's outside `app/` and `lib/`, so Rails never autoloads or eager-loads it.
   - It's loaded by one new file, `config/initializers/demo_mode.rb`, whose first line exits unless `DEMO_MODE=true`. Production doesn't set `DEMO_MODE`.
   - A spec proves that with the switch off, nothing is patched or loaded.

**Footprint goal: zero edits to existing files.** The branch adds only `demo/`, `config/initializers/demo_mode.rb`, `spec/demo/` and this doc. That also keeps `main → demo` merges conflict-free. A footprint check (`demo/bin/check_footprint`) lists any existing file the branch touched, and it should list none.

## What changes on the demo (what a salesperson sees)

| Screen | Today | After |
|---|---|---|
| Supplier Credentials | USF/PPO/WCW "Disconnected / Session expired" | Every login "Connected". **Validate** succeeds in ~2 s with no code prompt. **Import** reports up to date. **Add login** (e.g. Sysco for Brickell) connects right away. "Restaurants on this login" lists the demo's own restaurants. |
| Matched list | "Processing" forever | Matching and catalog search run on the demo itself, and the banner clears in seconds. These are local database work. The AI step is skipped because the demo has no AI key, so the existing name and pack-size rules do the matching. The stuck Downtown list is unstuck on the next boot. |
| Order review | Would wait for a price check that never runs | "Prices confirmed" right away (verified at the listed prices). Sysco delivery dates show the next few business days. |
| Submit / batch submit | Would sit in "processing" | "Submitted", with confirmation number `DEMO-<date>-<order id>`. No email goes out. |
| Everything else | Works (local DB only) | Unchanged: dashboards, reports, matching review, order builder, order history, order lists. |

## How it works (technical)

All files are new, under `demo/`:

- **`demo/network_wall.rb`:** in demo mode, every outbound HTTP connection is refused (`Net::HTTP`, so also Faraday), and launching a browser (Ferrum) raises. Email delivery is switched off. If we miss a button, it fails instead of reaching a supplier.
- **`demo/job_runner.rb`:** the demo's job queue (an Active Job adapter used only in demo mode) replaces "queue it for a worker that doesn't exist". It fails closed: a job class not on any list is dropped and logged.
  - **Local jobs** (matching, catalog search, categorising and other database-only jobs) run on a small background thread pool inside the web server.
  - **Supplier jobs** (validate, refresh, import, price check, place order, delivery dates, exception checks, restaurant linking, image mirroring) never run. `demo/simulator.rb` writes the result a successful run would have written.
  - **Mail jobs** are dropped.
- **`demo/simulator.rb`:** the fake supplier outcomes:
  - login → active, with a fresh last-login time
  - import → finished, nothing new
  - price check → verified at current prices, saved as a draft
  - place order → submitted, with a demo confirmation number
  - delivery dates → the next business days
- **`demo/overrides.rb`:** a demo-only `prepend`, so an active login counts as connected, and the restaurants page reads stored data instead of calling the supplier.
- **`demo/heal.rb`:** runs once at each demo boot.
  - Frees anything left stuck by the missing worker: lists stuck "matching"/"searching", logins stuck "pending"/"importing", orders stuck "verifying"/"processing".
  - Clears the demo's dead job queue.
  - Turns `checkout_enabled` off for every supplier, as a third layer. It must run after `seed_suppliers`, which turns it back on at every boot. Nothing on screen reads this flag.
  - Writes only to the demo database.

## Tests (`spec/demo/`)

- **Switch off (production behaviour unchanged):**
  - the initializer loads nothing
  - `Net::HTTP` is untouched
  - the queue adapter is still Solid Queue
  - `session_valid?` behaves exactly as today
- **Switch on:**
  - an outbound HTTP call raises
  - a Ferrum launch raises
  - every supplier job class is simulated, never performed
  - an unknown job is dropped
  - matching runs to "matched"
  - an order goes review → submitted with a demo confirmation, and `OrderPlacementService` is never built
  - a credential shows Connected
  - heal unsticks each stuck state
- **Footprint:** no existing file is modified on the branch.

## Rollout (each step needs Carmin's OK at the time)

1. Run the read-only demo DB probe. If real credentials are found, wipe their secrets on the demo before anything else.
2. Build on the `demo` worktree, with specs, then a full `bundle exec rspec`.
3. Install the pre-push hook.
4. Push the `demo` branch. Production doesn't build it.
5. Switch `demo-web`'s source branch from `main` to `demo` in Railway. This deploys the demo.
6. Click through the demo end to end: credentials, matched list, build an order, review, submit.

## Not in this round

- **Reset button:** a "Reset demo" button that restores a clean copy kept inside the demo's own database. That's a separate step, if wanted.
- **Stale snapshot:** the repo's `db/seeds/demo_data.sql.gz` is the March snapshot, and its scrub crashes. Never set `FORCE_RESEED=true` until that's replaced.
- **"List cleanup: 427 flagged pairs":** this banner is a real feature and works on the demo (local DB). It's left as is.
- **Banner wording:** "resets nightly at midnight" is inaccurate. It's left as is, to keep zero edits to existing files.
