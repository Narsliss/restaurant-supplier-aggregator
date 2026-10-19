# Morning stock run, all six suppliers (plan Phase 3)

**Date:** 2026-10-19 · **Branch:** `claude/charming-grothendieck-c1c08e` (worktree `adoring-taussig-b9eebc`) · **Status:** built and tested, NOT committed, NOT pushed · **Plan:** `docs/plan-out-of-stock-all-suppliers.md` Phase 3

## What Carmin asked for

A run every morning reads stock for ALL products, once per supplier. Items it finds out of stock can't go in a cart. Anything that sells out between that run and order time is caught at the price check (Phase 3.3 and US Foods' Phase 1.3).

## What this change does

1. **Records the evidence.** Every catalog run now stores, per product, what the supplier said about stock (`stock_signal`, the raw value), when it was read (`stock_checked_at`) and by what (`stock_source`: `catalog` or `guide`). Before this we only kept true/false, so "what did CW say at 8 AM?" had no answer.
2. **A per-supplier switch** (`suppliers.morning_stock_mode`), set on the Operations page:
   - **live** (the default after deploy, Carmin Oct 19 evening; see "Live from day one" below): the supplier's definite answer is written both ways, behind a guard.
   - **shadow**: record and count only. `in_stock` follows today's rule (a catalog run only ever marks items IN). The run counts how many items live mode would mark out and back in.
   - **live**: the supplier's definite answer is written both ways (out AND back in). "Can't tell" (nil) never changes anything.
   - **off**: record nothing.
3. **Each scraper maps its supplier's raw value** to in / out / unknown (live read-only probes, Oct 19):

| Supplier | Read from | Out when | Unknown when |
|---|---|---|---|
| US Foods | products v2 `inventory` (already fetched) | available cases ≤ 0 on a regular warehouse item | no inventory block, or not productType R |
| Chef's Warehouse | full category crawl, `variant.inStock` count | count is 0 | no count (used to be read as "in") |
| What Chefs Want | full browse crawl, `unavailable` | `unavailable` is true | field absent. `isOutOfStock` is NOT used: it depends on a delivery date we don't send |
| Performance | `IsOutOfStock` in the existing 6 AM search (was ignored) | true | field absent |
| Sysco | SearchProducts `stockIndicator` | `O`, phased out, or not orderable. D (demand), R and N stay in | n/a |
| Premiere Produce | availability list | `OUT_OF_STOCK` (never seen in a probe yet) | no entry |

4. **The 6 AM run reads the whole catalog** for Chef's Warehouse and What Chefs Want (it used to stop at 100 and 50 items per category; CW reached about 6% of its catalog). CW pages by page number up to the total CW reports, because its next-page token is unreliable on every login. Both crawls report categories that came up short (under 98% of the count) or failed, instead of logging "complete".
5. **The order-guide sync records evidence too** (`stock_source: guide`) when it reads an item's stock.
6. **Morning stock report** (`MorningStockReportJob`, 9:15 AM Eastern). For each supplier it shows when the run happened and how many items on lists got a stock reading today. It **emails the super admin only when something is wrong**: no run this morning, run errors, a short or failed crawl, or under 85% of list items read. Nothing is sent when all is well. At most one email a day. The Operations page shows the same table, with off/shadow/live buttons per supplier.
7. **Operations page:** order guides stuck "syncing" for over an hour now show as a red count. They used to show blue, like work in progress, for days.
8. **`recurring.yml`:** the descriptions now give Eastern times and say the 6 AM import uses the most recently used login, not a super admin's.

## Ordering impact

- **No cart, add-to-cart or submit code changed.** Every gate from Step 0 and Phases 1 and 2 is untouched.
- **In live mode (every supplier after deploy), the morning run marks items out and back in** from the supplier's answer, behind the guard below. Items the supplier says are available go back in, which clears the old stale "out" flags (D2) on the first morning.
- **Switching a supplier to live changes what chefs see:** out labels, the review-page warning, add-item search, the default/cheapest supplier, and split and minimum suggestions. For US Foods, "out" only warns (D1). For the other five, a cached "out" blocks desktop Submit until 3.3 replaces it with a live read.

## Deploy notes

- **One migration** (`20261019180000_add_stock_evidence`). It adds three nullable columns to `supplier_products` and two to `suppliers`; `morning_stock_mode` defaults to `live`. No data is rewritten.
- **Restart the worker after web migrates** (`railway redeploy --service worker --yes`, after checking it is idle). Until then the worker skips the evidence and imports exactly as before, instead of failing.
- **The CW 6 AM run gets longer:** about 300 pages, roughly 17 minutes, instead of a few minutes.
- **No switching needed.** Every supplier starts live. A supplier can still be set to shadow or off on the Operations page.

## What did NOT work / caught on the way

- **A boot crash, caught before deploy.** `db:migrate` boots the app, and the supplier seed (`config/initializers/seed_suppliers.rb`) saves every supplier at boot. The new `morning_stock_mode` validation read a column that didn't exist yet, so boot raised `NoMethodError` and the migration that adds the column could never run. Web would have crash-looped. **Fix:** until the columns exist, a supplier reads as "off" and the evidence is skipped. **Proven:** the new code booted on the pre-migration schema, then `db:migrate` ran cleanly, and the schema it produced matches `db/schema.rb`. The spec fails without the fix.
- **The test database is shared** by every worktree and the main checkout. Each test run reloads its own schema, so concurrent runs break each other. The pre-push hook runs the suite **in the main checkout** (the Stripe branch), not in this worktree. For this branch I ran the suite against a separate local database, `restaurant_supplier_aggregator_test_stock` (`DATABASE_URL=postgres:///restaurant_supplier_aggregator_test_stock`).
- **Miss tracking is skipped on the CW and WCW crawls.** A browse crawl can miss items that are only reachable by search. With full coverage, it would start counting misses toward "discontinued". In practice nothing changes: the old capped crawls covered under 60% of the catalog, so miss tracking was already being skipped for them.
- **WCW `isOutOfStock` is unusable** without WCW's real delivery date, so `unavailable` is used instead (1,492 stale WCW "out" flags trace to this).

## Specs

- `spec/services/import_supplier_products_stock_evidence_spec.rb`: shadow, live and off; unknown changes nothing; new items; the run summary; the pre-migration worker; miss tracking skipped.
- `spec/services/scrapers/catalog_stock_signals_spec.rb`: Performance, Sysco, US Foods and PPO mappings.
- `spec/services/scrapers/chefs_warehouse_scraper_spec.rb` and `what_chefs_want_scraper_spec.rb`: full crawls, short and failed categories, stock mapping.
- `spec/services/scrapers/chefs_warehouse_api_spec.rb`: no count reads as unknown.
- `spec/services/import_supplier_lists_service_spec.rb`: guide evidence.
- `spec/jobs/morning_stock_report_job_spec.rb`: quiet on success; flags no run, errors, a short crawl and low coverage; emails once a day.
- `spec/requests/admin_operations_stock_spec.rb`: panel, mode switch, unknown mode refused, admin only.
- `spec/models/supplier_spec.rb`: modes; reads as "off" before its column exists.

All 25 new Phase 3 specs fail on the previous commit's code, and the 117 older specs in those files still pass there.

## Open items

- **3.2 / D2:** the ~2,600 stale "out" flags. Live mode clears every item the crawl reads as available. Carmin decides whether to also run a one-time reset for items the crawl doesn't reach.
- **3.3:** live stock at the price check for CW, WCW, Performance, Sysco and PPO (US Foods is done). Until then a cached "out" from a live supplier blocks desktop Submit.
- **Sysco items it no longer lists** should go down the discontinued path, not "out" (not built).
- **Drop the extra local test database** when this branch is merged: `dropdb restaurant_supplier_aggregator_test_stock`.

## Live from day one, with a guard (Oct 19, evening)

**Carmin:** no two-morning shadow and no manual checks ("so you think I would manually check thousands of items?"). The shadow plan expected him to read "would mark out" totals before switching each supplier on; nobody should have to.

**What replaces it:** a guard in the morning run (`ImportSupplierProductsService#apply_held_outs!`).
- "Back in stock" is written as the crawl reads it. That's the safe direction: a wrong "in" is still caught at the price check and at checkout.
- "Out" is held until the run ends. If more than **25%** of the supplier's items on lists read out, nothing is marked out at that supplier that morning. The run records `held` (share, basis, count), the Operations page shows "held", and the 9:15 report emails the super admin once.
- With fewer than 20 list items read, the guard uses every item read.
- New products the supplier calls out are created in stock and marked out with the rest, so a broken reader can't create thousands of products as out on the first full crawl.

**Why 25%, not the 10% first suggested:** today's guide-sync flags already put 1% (US Foods, Premiere Produce) to 11% (What Chefs Want) of list items out. Those flags are partly stale, but 10% would trip on normal mornings. A broken reader shows 50–100%; What Chefs Want's `isOutOfStock` once marked everything out (fcf11a8).

**Specs:** `import_supplier_products_stock_evidence_spec.rb` "the held-outs guard": applies at 10%, holds at 60% and reports it, still marks items back in on a held morning, falls back to all items read, new items wait for the guard. Default is live (`supplier_spec`, `admin_operations_stock_spec`).
