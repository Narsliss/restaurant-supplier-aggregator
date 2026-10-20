# Fix: the 8 AM guide sync at scale

**Date:** 2026-10-20 · **Status:** approved by Carmin, built and tested (full suite 2106/0), not committed or pushed. It ships in one push with `fix-performance-api-refresh.md` · **Order placement:** no submit code changes. The sync writes the guide prices and stock chefs see before they order; each step states its impact.

## As built (Oct 20)

| Step | Files |
|---|---|
| 1. Sysco guide only | `sync_all_lists_job.rb`; `import_supplier_lists_job.rb` (`delivery_dates:`); `import_supplier_lists_service.rb#read_guide_stock!`; `import_supplier_products_service.rb#read_stock_for_list_items!` (shares `read_live_stock!` with the 6 AM read of list items the crawl missed) |
| 2. Lanes + queue | `SyncAllListsJob::STAGGER` per supplier; `list_sync` queue for `SyncAllListsJob`, `ImportSupplierListsJob`, `FetchSyscoDeliveryDatesJob`; new worker in `config/queue.yml` (6 threads); `config/recurring.yml` `sync_all_lists` queue |
| 3. Refusals | `MorningStockReportJob.refusals_since`; `ImportSupplierListsJob` keeps the errors its service caught in `ScrapingLog#metadata['errors']` |

**Where the build differs from the plan:**
- **The guide sync queues the delivery dates when it finishes,** instead of `SyncAllListsJob` queueing both at once. Both calls need the Sysco session. Run side by side, an expired session could open two browser logins for one account; in sequence, the dates call reuses the session the guide sync just checked. Dates are still fetched every morning for every Sysco login, including when the guide sync is skipped because it ran in the last 4 hours.
- **No "read in the last hour" skip on the guide stock read.** It was in the first build and never fired. The guide sync stamps every Sysco guide item `guide:in` with the current time (`refresh_linked_product`), even though Sysco's guide says nothing about stock, so every item looked freshly read. Every Sysco guide sync now reads its items: about 30 lookups for 600 items.
- **The refusal line is reported whatever a supplier's stock mode is,** since a supplier blocking us matters even with its stock check off.

**Found while building (pre-existing, now better for Sysco):** today's 8 AM Sysco run reads real stock in the catalog import, then its guide step overwrites the list items with that assumed `guide:in`. So Sysco list items have been showing the guide's assumption, not Sysco's reading. Now the real reading is written last and stays. Chef-pressed Sysco syncs get the same fix. US Foods' guide sync probably has the same pattern (Oct 20 review, unverified) and isn't touched here.

Source: the Oct 20 Railway and scaling analysis. Two parts of the 8 AM sync (`SyncAllListsJob`, `config/recurring.yml` `sync_all_lists`) grow with every restaurant. Both are fine at today's 7 locations and break somewhere between 20 and 100 restaurants.

## Step 1: Sysco syncs the guide only at 8 AM

**Today (code):**
- `SyncAllListsJob` sends every Sysco login (one per supplier per org) to `SyscoCombinedImportJob` (`sync_all_lists_job.rb:30`).
- Each of those runs does the full catalog work before the guide: catalog term search (about 8,400 items, about 20 min per `morning-jobs-audit.md`), `refresh_known_products`, `heal_unitless_pack_sizes`, a stock read for unread list items, then the guide, then delivery dates.
- The 6 AM run (`StaggeredSupplierImportJob` → `SyscoCombinedImportJob`, best login) already does all of that catalog work once a day.
- Each catalog run copies its prices onto **every** customer's Sysco list items (`sync_prices_to_list_items`, `import_supplier_products_service.rb:570`). After the 8 AM run, every Sysco customer except the last one sees the last login's catalog prices on shared items until the next morning. Sysco is contract-priced, so this is probably a real price mix-up already; not confirmed in production.

**Change:**
- **Guide:** at 8 AM, Sysco logins go to `ImportSupplierListsJob` like the other five suppliers. `SyscoScraper#scrape_lists` already runs `ensure_api_session!` + `scrape_supplier_lists`, which prices each item under that account (`price_with_sellers`).
- **Delivery dates** (per account, needed for ordering): `SyncAllListsJob` also queues `FetchSyscoDeliveryDatesJob(credential.id, force: true)` for each Sysco login.
- **Stock, kept as fresh as today:** Sysco's guide data has prices but no stock. After a Sysco guide sync, read stock for that login's guide items with `live_stock_for`. It's the same item-number lookup the order price check uses, 20 items per call, so about 30 calls for 600 items, applied with the existing evidence rules (`apply_stock_evidence!`). A failed stock read never fails the guide sync.
- **The 6 AM run doesn't change.** The catalog is imported once a day.

**Ordering impact:**
- Nothing changes in the cart or submit code.
- From 8 AM on, Sysco guide prices become each account's own. Today they end up as whichever login ran last.
- Delivery dates and stock stay per login.

## Step 2: one lane per supplier instead of one line for everyone

**Today:** every login waits in one line, started 30 seconds apart across all suppliers (`index * 30.seconds`). The jobs run on the scraping+low worker, which has 2 threads shared with the catalog imports. A chef's own "Sync" press uses the same queue and can wait behind a 20-minute import.

| Restaurants (about 4.5 logins each) | Last guide starts after 8 AM, today |
|---|---|
| 7 locations today | minutes |
| 50 | about 1 h 50 m |
| 100 | about 3 h 45 m |
| 250 | about 9 h |

**Change:**
- **Separate gaps per supplier:** the 30-second gap counts within each supplier's own logins. The six suppliers run side by side, and each supplier still sees at most one new login every 30 seconds, which is our rate limit per supplier.
- **Its own queue:** `ImportSupplierListsJob` (and `FetchSyscoDeliveryDatesJob`) move to a new `list_sync` queue with its own worker process at about 6 threads. Guide syncs stop waiting behind catalog imports, chefs' Sync presses get answered faster, and the import process's memory isn't pushed up.
  - The production DB pool is `RAILS_MAX_THREADS + 5` = 10 per process, which is enough.
  - One more process costs about 0.2 GB, or **+$2–3 a month**. `critical` stays isolated for `PlaceOrderJob`.

| Restaurants | Last guide starts after 8 AM, after the change |
|---|---|
| 100 | about 40 min |
| 250 | about 1 h 30 m |

Past about 250 restaurants, shorten the per-supplier gap or allow 2 at a time per supplier. That's a setting to tune, not a redesign.

**Ordering impact:** none on submit. Guides are fresh earlier in the morning.

## Step 3: know when a supplier pushes back

All supplier traffic leaves from one Railway address. With many more logins, a supplier may start rate-limiting (HTTP 429) or blocking (HTTP 403).

**Change:** count this morning's guide-sync and import failures with HTTP 429 or 403 in the error, per supplier (`ScrapingLog`), and add a line to the existing 9:15 morning stock email. That email is sent only when there's a problem, so it stays quiet on success.

**Ordering impact:** none.

## Tests (written with the code)

- `SyncAllListsJob`:
  - Sysco logins get `ImportSupplierListsJob` + `FetchSyscoDeliveryDatesJob` and never `SyscoCombinedImportJob`.
  - The stagger restarts for each supplier.
  - Jobs land on `list_sync`.
- `StaggeredSupplierImportJob` still uses `SyscoCombinedImportJob` at 6 AM.
- The Sysco guide-item stock read follows the evidence rules, and its failure doesn't fail the sync.
- `config/queue.yml`: the `list_sync` worker exists and `critical` is still alone.
- The morning report shows the refusal line only when there are 429/403 failures.

## Rollout

- One push with the Performance refresh fix (`fix-performance-api-refresh.md`), sent while the worker is idle. A deploy mid-order can double an order until the order-safety work lands.
- The first run is the next 8 AM. Check the guide-sync logs per supplier, that Sysco delivery dates were fetched, the 9:15 report, and the new worker's memory in Railway.

## Options considered and rejected

- **A per-supplier cap with `limits_concurrency`:** Solid Queue 0.9 allows one limit per job class, and `ImportSupplierListsJob` already uses it to stop duplicate syncs of one login.
- **More threads on the existing scraping worker:** catalog imports share it, so heavy imports could overlap and push memory up.
- **Dropping Sysco's 8 AM stock read:** cheaper, but stock would be only from 6 AM and from one login's location. It's per location everywhere else.

## Open items

- **Not yet run against live suppliers.** The specs stub Sysco's guide, stock lookup and delivery dates. The first real run is the 8 AM after the push. Check it with the rollout list above.
- **The new worker's memory.** Expect about +0.2 GB in Railway. Check after a few days, since the other processes climb as they run.
- **Owner multi-restaurant Sysco logins** read stock once per restaurant (each after its switch), which is right for per-location stock. Not yet seen live.

## Not in this plan

- **Catalog prices copied into other customers' guides for the other suppliers.** Their 6 AM import still copies the importing login's prices onto every guide until each customer's 8 AM sync. This belongs with regional catalogs (before the first restaurant outside the Cincinnati area).
- **Running imports in a process that exits** (memory and cost).
- **Order safety:** a separate session, with its own plan.
