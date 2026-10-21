# Record: the demo site never talks to a supplier

**Date:** 2026-10-20
**Branch:** `demo`, in the worktree `.claude/worktrees/demo-site`. Not committed or pushed. It never merges into `main`.
**Plan:** [plan-demo-site-offline-suppliers.md](plan-demo-site-offline-suppliers.md), approved by Carmin with "build the local branch for me to test on a local server before you push literally anything".
**Status:** LIVE on the demo since Oct 21 00:34 UTC (demo-web builds from `demo`). Carmin clicked through the live demo: credentials connected, the matched list done, and an order went through to a demo confirmation. Production is unchanged.

## What changed

All files are new. No existing file is edited (`demo/bin/check_footprint` passes).

| File | What it does |
|---|---|
| `config/initializers/demo_mode.rb` | Exits on its first line unless `DEMO_MODE=true`; otherwise loads `demo/` |
| `demo/demo_mode.rb` | The switch, and wiring the pieces in |
| `demo/network_wall.rb` | Refuses outbound HTTP, raw TCP to non-loopback hosts, and browser launches. Its error is a `SocketError`, so existing outage handling copes |
| `demo/job_runner.rb` | The demo's job queue (there is no worker), described below the table |
| `demo/simulator.rb` | What each supplier job would have written had it succeeded |
| `demo/overrides.rb` | An active login counts as connected; "restaurants on this login" reads stored data instead of calling the supplier |
| `demo/heal.rb` | Runs on the first request after boot, then daily, in the background |
| `demo/bin/check_footprint` | Lists anything the branch changes besides new demo-only files |
| `demo/bin/pre-push-guard` | Git hook that refuses any push to `main` carrying demo code. Written and tested, **not installed** |
| `spec/demo/*` | 46 examples |

How the job runner treats each job:
- **Database-only jobs** (matching, catalog search, and similar) run on 2 threads in the web process.
- **Supplier jobs** are replaced by simulated outcomes.
- **Everything else** (mail, alerts, sweeps, resets, any unknown job) is dropped.

What the heal does on the demo's own database:
- Overwrites every saved login with placeholders.
- Replaces email suppliers' contact addresses with placeholders.
- Turns `checkout_enabled` off.
- Unsticks matched lists, orders and 2FA requests.
- Empties the dead Solid Queue backlog.
- Freshens catalog sync times and Sysco/Performance delivery days.
- Moves each organization's *placed* orders forward so the newest is today.

## Why

On the demo (`RAILS_ENV=production`, no worker), Puma never runs jobs (`config/puma.rb`). So every queued job waited forever:
- matching left the list on "Processing"
- price checks and order placement could never finish
- sessions were never refreshed, so 2FA logins showed "Disconnected / Session expired"

The fix had to be impossible to reach production. Hence a separate branch, demo-only paths, a switch-gated loader, and patches that re-check the switch on every call.

## Verified

- **Production boot, switch off:** `RAILS_ENV=production` with eager load, as production boots. Nothing from `demo/` is loaded, the adapter is Solid Queue, nothing is patched, mail delivers. Same boot with `DEMO_MODE=true`: everything is installed. Both are in `spec/demo/boot_spec.rb`.
- **Full suite** on the branch, on its own test DB `restaurant_supplier_aggregator_test_demo`: 2,206 examples, 0 failures, including the 46 demo specs. An earlier run in random order (seed 28695) also had 0 failures.
- **Local click-through** at http://localhost:3100, as owner and as chef, on a copy of the dev database:
  - All six suppliers show Connected.
  - "Sync New Products" finished in about a second, with no spinner left.
  - Build order → review "Verifying prices…" → "Order saved as draft" → Submit → Order #445 **Submitted**, `DEMO-20261020-445`, lines "Added".
  - Import and "Add login for Downtown Bistro" (Sysco) connected without contact.
  - The log shows 0 blocked outbound attempts, because the simulator means no code path even tried.
- **Push guard**, tested on a commit object no branch points to: refuses demo code to `main`; allows normal `main` pushes, a new `demo` branch, and `main` to a new remote.

## Live demo probe (Oct 20, run by Carmin; read-only, counts only)

**Safety:**
- No Chromium, no mail key, no Stripe key, no worker process (`SolidQueue::Process` = 0).
- `checkout_enabled` is **on** for the 6 scraper suppliers (set by `seed_suppliers` at boot); the heal turns it off.

**People:**
- 1 organization: Bella Vista Restaurant Group.
- 5 users, all on demo domains (`bellavista.demo` 2, `test.com` 2, `testing.com` 1). No real customers.

**Saved logins:**
- 10 logins, 2 per supplier, all at Bella Vista Downtown, all `active`.
- **None can be decrypted on the demo.** Every username and the 4 stored passwords were copied in the Aug 13 rebuild, encrypted under the source machine's development key.
- No saved sessions and no trusted-device tokens.
- The heal overwrites all of them with placeholders, without needing to read them.

**Email supplier:** Blue Ribbon's order address is a `hotmail.com` address, shown on the Suppliers page. The heal replaces it.

**Stuck states, all from the night of the rebuild:**
- The Downtown matched list has been `matching` since 2026-08-13 23:35 (976 matches).
- 6 jobs are queued for a worker that never existed: 5 `ImportSupplierListsJob`, 1 `SyncNewProductsJob`.
- 1 order is `processing`.

**Stale data:**
- Catalog last synced Aug 11-13; Sysco's catalog on May 6.
- **All 10 logins hold delivery days from August**, not just Sysco's.

**Replayed locally:** these states were recreated on the local copy (the list stuck, the queued jobs, an order processing, logins this server can't decrypt, August delivery days, a hotmail address). One page visit healed every one.

## What did NOT work at first (fixed)

- **Delivery days, found by the probe:** the heal refreshed only Sysco and Performance. The builder and review page show stored days for every login, so the other four suppliers would have offered August dates. It now refreshes every login that has stored days; a login with none keeps none. Also, `where.not(col: [])` on a JSON column matches every row in Rails, so the query uses `<> '[]'::jsonb`.

- **History shift:** the first version shifted all orders by the newest order of any kind. A recent draft anchored it, so the dashboard stayed at $0. It also pulled old failed orders into this week as a red "2 orders NOT placed" alarm. Now it anchors per organization on placed orders and moves only placed orders.
- **Login scrub:** the first version read old values through the model. A login encrypted under another key (any copied database; the March snapshot crash) would make it fail. It now writes freshly encrypted placeholders straight into the columns.
- **Test helper leak:** clearing Rails' per-class test adapter on every job class leaked out of the example and broke 36 unrelated specs. It now clears only `ActiveJob::Base`, which Rails resets after each example.
- **Repo hook:** the `git push` rspec hook (`.claude/settings.json`) also fires on shell `for` loops and `$(…)` substitutions. Commands were kept simple to avoid surprise full runs.

## Found in passing (not demo work)

- **Owner view bug, also in production:** on Supplier Credentials, owners see "Catalog sync pending" on every per-restaurant login (Sysco, Performance). `SupplierCredentialsController#index` computes `@catalog_last_synced` after the owner view has split the per-restaurant logins out of `@credentials`. The fix belongs on `main`, not here.
- **Real address in data:** the dev database's "Blue Ribbon" email supplier holds what looks like a real person's address. The demo heal replaces it; the dev data itself is unchanged.

## Not verified

- **Menu Planner sending a new request:** it needs an AI key the demo lacks, so expect the app's own error message. Existing plans display fine.
- **Mobile layouts.**
- **Performance delivery days in the builder.**

## Open items (each needs Carmin's OK at the time)

1. ~~Run the read-only probe on the real demo.~~ Done Oct 20 (above).
2. ~~Commit on `demo`. Install `demo/bin/pre-push-guard` as `.git/hooks/pre-push`.~~ Done Oct 20: `32d839f`; guard installed and tested.
3. ~~Confirm production's two services build only from `main` (a read-only production check), then push `demo`.~~ Done Oct 20:
   - Web and worker build from the repo, and all 40 of their recent deploys came from `main`. The 12 other branches already on GitHub never triggered one.
   - `origin/demo` is `fda2b44`. Production's latest deploy is still `fe228e9`, from before the push.
   - Never open a pull request from `demo`.
4. ~~Switch `demo-web`'s source branch to `demo` in Railway.~~ Done Oct 21 00:34 UTC:
   - Carmin switched it in the dashboard; deploy `fda2b44` from `demo` succeeded.
   - Production's latest deploy is unchanged (`fe228e9`, 00:02 UTC).
   - One anonymous visit to the sign-in page ran the heal, which took about 6 s with no step failures and moved organization 6's placed orders forward 184 days.
   - **Bug found in the boot logs.** The "[DemoMode] Installed…" log line went to stdout (`RAILS_LOG_TO_STDOUT=true`), so it landed inside the values `bin/docker-entrypoint` (table count) and `bin/start` (user count) capture from `rails runner`.
     - On this boot both still took the right branch: "Migrations done", "Database already seeded".
     - On an empty database, the seed check would no longer read `0`.
     - The fix removes the line, with a boot spec that `rails runner 'puts 42'` prints exactly `42` in demo mode. It needs a commit and push to `demo`.
5. Never set `FORCE_RESEED=true` on the demo. It would reload the March snapshot, whose scrub crashes.
6. Possible later steps:
   - a "Reset demo" button
   - fixing the banner, which says "resets nightly at midnight" (that's an existing file, so it would come from `main`)
   - the owner-view "Catalog sync pending" bug, fixed on `main`

## Testing locally

- **URL:** http://localhost:3100. Use the quick sign-in buttons (password `Demo1234!`, set on the local copy only).
- **Server:** the `demo-local` entry in the main checkout's `.claude/launch.json`. It runs Puma from the worktree with `DEMO_MODE=true` on `restaurant_supplier_aggregator_demo_local`, without the in-Puma job plugin, like the real demo.
- **Starting over:** stop the server, then run the scratchpad `reset_local_demo.sh`. It drops the local demo DB and copies the dev DB again; the dev DB is only read.
