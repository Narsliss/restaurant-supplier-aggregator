# What runs every morning, what it collects, and why it silently misses restaurants

**Date:** 2026-10-19 · **Status:** investigation only, nothing changed · **Trigger:** D'oro order 483 (walnuts/chilis/leeks out of stock, chef gave up and ordered in CW's app). Carmin asked: what runs every morning, what data does it collect, why are there errors, why only one account, and why no alert.

Sources: `config/recurring.yml`, job/service code, worker logs Oct 13-19, read-only production queries, one read-only live CW call at 2:31 PM.

## 0. The walnuts, first (Carmin was right)

The walnuts were **not** missed because of which login synced.
- Alfio's own CW sync ran at 8:02 AM and read the walnuts on alfios' guides as in stock (CW's count was above 0).
- At 2:31 PM the same login's guide returns `inStock: 0.0` for the walnuts, and our parser reads that as out of stock.
- So the walnuts sold out between ~8 AM and 12:19 PM, and the chilis and leeks between 12:22 and 1:47 PM.
- The real gap is **timing**: our only stock read is the 8 AM guide sync, and nothing re-checks before the chef orders.
- Carmin's assumption holds for CW stock: one login sees the same stock as the others (Alfio's account shows the walnuts out now, same as D'oro).
- The "one login per organization" coin flip (section 3) is a separate, real problem. It keeps whole restaurants' guides, prices and list status stale, but it is not why the walnuts weren't flagged.

**What the 8 AM run did today (read-only prod check).**
- **How stock is written.** Every guide item's stock is rewritten from CW's count on each sync (`import_supplier_lists_service.rb` `upsert_item`), then copied both ways onto the shared product row (`refresh_linked_product`).
- **CW overall.** 355 shared rows got a stock read between 8 and 9 AM; 33 of them were marked out of stock. The morning read works where it runs.
- **Order 483's 27 items:**
  - **20 got a fresh 8 AM stock read**, the walnuts included (in stock at the time), via alfios'/Noche's guides.
  - **3 only had the 6 AM catalog import**, which can never mark an item out: Red Fresno Chilis, Leeks, Half and Half.
  - **4 had no read today:** toilet tissue and Fuji apples (last touched Oct 14), beets and spring water (Oct 17, D'oro's last sync).
- **D'oro's CW list products:** 237 of 451 (53%) got a stock read this morning, all through the other restaurants' guides. 88 only had the catalog import; 126 had nothing today.
- **Not provable today:** the actual count CW gave at 8 AM. We store only true/false, and nothing is logged per item.

## 1. The schedule (all times Eastern)

The app's time zone is Eastern (`config/application.rb: config.time_zone`), and Solid Queue reads crons without a zone in that time zone. Proof: `sync_all_lists` ("0 8 * * *") was enqueued at 12:00 UTC = **8:00 AM ET**. The descriptions in `recurring.yml` saying "4 AM EST (8 AM UTC)" and "2 AM EST (6 AM UTC)" are wrong by four hours.

| Time (ET) | Job | What it's for |
|---|---|---|
| 12:00 AM | StaggeredDeepImportJob | Full-catalog crawl, one supplier per night (weekly rotation) |
| 3:30 AM Wed | ChefsWarehouseCatalogPricingJob "all" | Re-price every CW catalog item |
| 4:15 / 4:30 AM | ClearFinishedJobs / ExpireDrafts | Housekeeping |
| 5:00 AM | UsFoodsExceptionSweepJob morning | Re-check US Foods orders delivering today |
| 5:30 AM | ChefsWarehouseCatalogPricingJob "unpriced" | Price new CW catalog items |
| 6:00 AM | StaggeredSupplierImportJob | Daily catalog import, per supplier |
| 7:00 AM | BuildComparisonCandidatesJob | Cross-supplier alternatives for savings |
| **8:00 AM** | **SyncAllListsJob** | **Order guides / lists: prices + stock for what each restaurant buys** |
| 10:30 AM | AutoLinkSupplierRestaurantsJob | Link new supplier restaurants to owners' EnPlace restaurants |
| 11:00 AM | MatchHealthCheckJob | Email super admin about emptied matched-list rows |
| every 2 h | RefreshAllSessionsJob | Keep supplier logins alive |

## 2. Which login each job uses, and what it writes

**One fact shapes everything:** `supplier_products` is ONE row per supplier + SKU, shared by every organization and restaurant (unique index `[supplier_id, supplier_sku]`, no org or location column). A list item's stock reads that shared row (`SupplierListItem#in_stock`). So price and stock are global, whoever wrote them last.

| Job | Login used | Writes | Reads stock? |
|---|---|---|---|
| Deep import (midnight; CW Sun, WCW Mon, PPO Tue) | Any active login platform-wide, live session first (`deep_catalog_import_job.rb:82-98`) | Catalog rows: names, packs, prices, images | Same rule as the 6 AM import (below), with no miss tracking |
| CW catalog pricing (5:30 AM; Wed all) | Any active CW login platform-wide (`chefs_warehouse_catalog_pricing_job.rb:100-104`) | That login's price on the shared rows | **No** |
| Catalog import (6 AM) | **One login per supplier for the whole platform**: active, live session first, most recently used (`staggered_supplier_import_job.rb:61-71`). Not super admin, as `recurring.yml` claims. | Names, packs, **that login's prices** onto the shared rows, copied to **every org's** list items (`import_supplier_products_service.rb:549-597`) | **Can only mark items IN stock, never out** (`resolve_stock_status`, `:350-356`). The only "out" is discontinue after 3 misses. US Foods, WCW, Performance: stock not read at all. |
| Comparison candidates (7 AM) | none | Savings alternatives | n/a |
| **List sync (8 AM)** | **One login per supplier per organization** (section 3) | Order-guide items for that login's restaurants, and onto the shared row: price, pack, **stock both ways** (`import_supplier_lists_service.rb:309-362`) | **The only place an item is ever marked out of stock.** Except US Foods, where "in stock" just means "USF returned the product" (`us_foods_scraper.rb:438`), so USF stock is never read. |
| Auto-link (10:30 AM) | Owner/manager logins in multi-restaurant orgs | Restaurant-picker links; a new link forces a list sync | n/a |
| Session refresh (every 2 h) | Every login idle more than 6 h | Session/login fields only | n/a |

### Is one account enough?

- **Catalog (what exists, pack sizes): yes.** It already runs on one login per supplier for the whole platform.
- **Prices: no.** Prices are per account (contract pricing), but one login's price is written onto the shared row that every restaurant sees. The guide sync then overwrites it with whichever restaurant's guide synced last.
- **Out of stock: not as built.**
  - No job asks a supplier "is this item in stock?" for the items restaurants buy.
  - The 6 AM catalog import reads CW, PPO and Sysco stock counts but deliberately never marks anything out.
  - The only out-of-stock signal is a side effect of reading each restaurant's own order guide at 8 AM. Order guides are per restaurant: D'oro's guide is only visible to a D'oro login. So the stock signal exists only for items on the guides of the restaurants that got synced that day.
  - Off-guide items (D'oro's chilis and leeks) get no stock signal at all.
  - Stock itself looks warehouse-wide: Alfio's account showed the walnuts out of stock just like D'oro's refusal. So one login *could* cover stock for a supplier's whole region **if** we asked per SKU close to order time. Nothing does that today, and a once-a-day 8 AM read is stale by lunch.
- **Order guides: no, one login per restaurant is needed,** because each restaurant's guide lives in its own account.

## 3. The 8 AM list sync picks ONE login per supplier per organization, by coin flip

`SyncAllListsJob#one_credential_per_supplier_per_org` (`app/jobs/sync_all_lists_job.rb`) groups an organization's logins by supplier and keeps one: active over expired, then owner > manager > member. Alfio's group (org 7: alfios, Noche, D'oro) has several **owner** logins per supplier. Alfio himself has a CW login with a restaurant picker covering alfios + Noche (cred 72), and a separate CW login for D'oro (cred 135). Same for US Foods (75 vs 132). Both are active and both are owner, so `min_by` ties, and the first row of an unordered query wins. Which restaurant gets refreshed changes day to day (worker logs):

| Org 7 | Oct 13 | Oct 14 | Oct 15 | Oct 16 | Oct 17 | Oct 18 | Oct 19 |
|---|---|---|---|---|---|---|---|
| Chef's Warehouse | D'oro (135) | D'oro | D'oro | alfios+Noche (72) | D'oro | alfios+Noche | alfios+Noche |
| US Foods | D'oro (132) | D'oro | alfios (75) | D'oro | D'oro | alfios | D'oro |

The whole run is 12 logins across 4 organizations. Org 7 alone has 36 supplier logins across 3 restaurants: US Foods 9, CW 9, PPO 8, WCW 5, Performance 4, Sysco 1.

**Other ways a skipped restaurant's lists can sync:** the Import / Sync / Refresh buttons, a new restaurant link, credential validation and 2FA completion. The last two hit an organization-wide 4-hour skip (`import_supplier_lists_job.rb:34-45`): if ANY restaurant's list for that supplier synced in the last 4 hours, every other restaurant is skipped too. No scheduled job ever covers the logins that weren't picked.

## 4. Why lists get stuck in "syncing" (35 today) and wrongly "failed" (some of the 11)

1. **Everything is marked "syncing" up front, but only some of it gets synced.** `ImportSupplierListsJob` marks **every** list for that supplier in the organization as `syncing` (`import_supplier_lists_job.rb:58-61`). Then it syncs only the chosen login's restaurants. The other restaurants' lists stay `syncing` until their login wins a later coin flip:
   - D'oro's CW lists: since Oct 17.
   - alfios' and Noche's US Foods lists: since Oct 18.
2. **Errors are swallowed, so the cleanup never runs.** `ImportSupplierListsService#call` rescues every error (`:87-96`) and returns normally. The job then records the run `completed` (`mark_completed!`, `:72`) even if it failed. Its rescue, which resets stuck `syncing` lists to `failed`, is never reached.
3. **A single-restaurant login marks the other restaurants' lists "no longer found".** When D'oro's login wins, alfios'/Noche's lists it can't see are marked `failed — List no longer found on supplier site`. That removal check is scoped by organization, not restaurant (`import_supplier_lists_service.rb:490-505`). Some of the 11 failed lists are real deletions; some are this.
4. **A killed worker (deploy or restart mid-sync)** marks the job failed without running its rescue or ensure, so the lists stay `syncing` (Solid Queue 0.9.0).

Stuck `syncing` doesn't block the next sync. The real damage is that those restaurants' prices and stock silently go stale.

## 5. Why nobody was told

- **No error is ever raised.** A sync that picks the "wrong" login finishes normally. All scraping logs in the last 7 days are `completed` (CW 28/28, USF 28/28, WCW 28/28, PPO 15/15, Sysco 7/7, Performance 14/14). The newest failed Solid Queue job is from Aug 25.
- **The daily health email is never sent.** `ScrapingErrorMailer#daily_health_summary` exists, but nothing calls or schedules it.
- **The Operations page counts, it doesn't judge.** `admin/operations` shows list statuses as counts. "syncing" is drawn in blue (in progress), with no age check, so 35 lists stuck for days look like activity. The success rate is per run, not per restaurant covered.
- **Failure emails cover only the catalog import** (`ImportSupplierProductsJob` → `ScrapingErrorMailer.import_failed` / `no_credentials`). Nothing emails on list-sync problems.
- **This breaks the "quiet success, alert on failure" rule.** Here the failures are quiet too.

## 5b. Stock should be checked per SKU, not per restaurant (Carmin, Oct 19)

Stock is the same across Alfio's restaurants (same CW warehouse), so syncing every restaurant to get stock would be wasted work. The gap is **which SKUs** get a stock read, not which restaurant:
- The 8 AM sync only learns stock for SKUs on the guides it happens to read.
- The 6 AM catalog import reads CW's stock counts but is coded never to mark anything out.

Scale (prod, all organizations):

| Supplier | List rows, all restaurants | Distinct SKUs on lists | Distinct SKUs ordered, last 90 days | Catalog |
|---|---|---|---|---|
| US Foods | 3,404 | 800 | 87 | 10,076 |
| Chef's Warehouse | 2,527 | 644 | 89 | 15,857 |
| What Chefs Want | 745 | 310 | 63 | 6,997 |
| Premiere Produce | 713 | 339 | 44 | 2,318 |
| Sysco | 639 | 586 | 4 | 18,247 |
| Performance | 503 | 221 | 4 | 3,433 |

A once-a-day stock read per distinct SKU, with one login per supplier (per warehouse region), grows with what restaurants buy, not with how many restaurants there are. Restaurants overlap heavily (CW: 2,527 rows → 644 SKUs). It writes the one shared `supplier_products` row per SKU that already exists, so there's no per-restaurant duplication. A different login is only needed if a restaurant is served by a different warehouse (out-of-region; see the regional-catalog risk).

Per-restaurant guide syncing is a separate question (each restaurant's guide and contract prices), not a stock one.

**We already have most of this job; it ignores "out".** The 6 AM catalog import already runs one login per supplier and reads CW's stock counts. This morning it touched the chilis and leeks at 6:05. But since **commit 042aa34 (Mar 24 2026)** it can only mark items back IN stock, never out. That commit's reasoning: "Stock availability is location-specific, so catalog imports should never mark items out of stock — only the per-user order guide sync has the right context."
- Today's evidence (Alfio's login shows the same walnut stock as D'oro's refusal) says that assumption doesn't hold for restaurants on the same warehouse.
- The catalog import doesn't read stock at all for US Foods, What Chefs Want or Performance.
- It may not reach every item every day (the shallow import caps items per category).

## 6. Proposed fixes (not built, waiting for Carmin)

1. **Sync every restaurant every morning:** one login per restaurant per supplier, chosen deterministically. Prefer a picker login that covers several restaurants, and add a login for any restaurant it doesn't cover. Drop the organization-wide 4-hour skip in favor of a per-restaurant one.
2. **Mark only the lists being synced as `syncing`.** Record a run with errors as `failed`, not `completed`, and reset stuck lists on failure.
3. **Morning coverage alert:** after the 8 AM sync, check every restaurant × supplier with an active login. If its guide didn't sync today, alert the super admin (in-app and email). Also wire up or replace the never-sent `daily_health_summary`. On the Operations page, show `syncing` older than an hour in red with its age.
4. **Stock the chef can trust:**
   - A live stock check when the order is reviewed or submitted. A morning snapshot can't cover lunch; chilis and leeks went out between 12:22 and 1:47 PM.
   - Read real US Foods stock.
   - Let the 6 AM import mark items out of stock when the supplier says so.
5. **Fix the wrong `recurring.yml` descriptions** (times 4 hours off; "super_admin credentials").

## 7. Plan: Chef's Warehouse morning stock, one login, every item (proposed Oct 19, not built)

**What we found while planning.**
- **The 6 AM CW import is not a catalog scan.** It reads the first 100 items of each of 11 top categories, about 1,100 of ~15,900 (7%), in 26 seconds. It is the same items every day.
- **The weekly "full" CW crawl (Sunday midnight) only works on some logins.** It uses the most recently used CW login from any restaurant:
  - Oct 4, Sky's login: 512 items in 13 s (one page per category).
  - Oct 11, Nate's login: 13,876 items in 17 min.
  - Oct 18, Cody's login: 512 items in 12 s.
  - Each short run logged "complete", and the login used isn't logged.
- **CW's price call has no stock field.** Only the guide and category-browse calls do, so reading every item means paging every category.

**Steps.**
0. **Find why some logins get only one page.** A read-only live browse with a "short" login vs a "full" one, comparing CW's `total` and page token. The result decides how the login is picked.
1. **Full CW crawl every morning** (~5:00 AM ET, ~17 min, ~300 page requests, one login).
   - Use a login that pages. Detect a short crawl (CW's category total above what we fetched, or no next-page token while more exist), retry once with another login, and log which login ran.
   - This replaces the capped 6 AM CW import and the Sunday CW slot.
2. **Record what CW said:** two new columns on `supplier_products`, `stock_count` and `stock_checked_at`. No new rows; it's the one shared row per item. (Migration → restart the worker after deploy.)
3. **Shadow for two mornings:** record counts without changing `in_stock`. I report how many items would flip and spot-check them on CW's site. This guards against items CW shows as 0 but still sells (special-order / drop-ship stocking types).
4. **Turn it on:** a count of exactly 0 → out of stock; above 0 → back in stock; a missing count → no change. CW only; other suppliers unchanged.
5. **Quiet success, alert on failure:** email Carmin only when the morning stock run fails, comes up short, or doesn't run. The Operations page shows last run time, items checked and out-of-stock count.
6. **Specs and docs:**
   - downgrade only on a definite 0
   - missing count keeps the old value
   - other suppliers untouched
   - a short crawl is detected and alerted
   - the counts get recorded

**Scale.** CW calls and DB writes are per catalog item, flat as restaurants grow. ~300 page requests a day, and an update to the ~16k existing CW rows once a day (the Sunday crawl already does this weekly).

**Ordering impact.**
- **No placement gate changes.** CW's cart checks stay as they are. Pre-validation already skips the cached stock check for CW ("supplier decides").
- **What chefs see changes:**
  - "Out of stock" labels in the builder.
  - The review page's out-of-stock warning before submit (`orders_controller.rb:729`).
  - The builder's cheapest/default supplier, split-order and minimum suggestions skip out-of-stock CW items (`product_match.rb:134-404`, `split_order_service.rb:158`, `minimum_suggestion_service.rb`).
- **Risk:** a wrong "out" steers chefs away from CW for that item until the next morning. That's why step 3 shadows first.

### Other suppliers (same gap, different shapes; verified in code Oct 19)

| Supplier | Morning catalog read carries stock? | Can it mark "out" today? | Only source of "out" today | Next step |
|---|---|---|---|---|
| Chef's Warehouse | Yes: count (`variant.inStock`) | No (up-only since 042aa34) | 8 AM guide sync | This plan |
| Sysco | Yes: `stockIndicator == 'O'`, orderable, phased out (`sysco_scraper.rb:2955-2957`) | No (up-only) | 8 AM guide sync | Same pattern; check whether its known-SKU refresh can carry stock |
| Premiere Produce | Yes: `availability_status` for tomorrow's delivery (`premiere_produce_one_scraper.rb:171, 202`) | No (up-only) | 8 AM guide sync | Same pattern; small catalog (2.3k); stock is per delivery date |
| What Chefs Want | No: `in_stock: nil`, "only order guide is authoritative" (`what_chefs_want_scraper.rb:842`) | No | 8 AM guide sync (`unavailable`) | Recon: does WCW's catalog data have a stock field? |
| Performance | No: `in_stock: nil`, "per-location context" (`performance_scraper.rb:537`) | No | 8 AM guide sync (`IsOutOfStock`) | Recon |
| US Foods | No: `in_stock: nil` (`us_foods_scraper.rb:260`) | No | **Nothing.** The guide sync's "in stock" just means USF returned the product (`:438`) | Recon. Biggest gap; USF also has no cart line check (fix-cw doc, A1) |

Every supplier rests on the same assumption, "stock is per location, so only the per-restaurant guide sync may mark out". It's in commit 042aa34 and in the USF/WCW/Performance comments. The new pieces (`stock_count`/`stock_checked_at`, a definite-zero rule per supplier, shadow mode, the morning alert) work for any supplier, so CW can be the pattern.

## 8. Six-supplier stock plan (draft, Oct 19; nothing built)

### What the morning runs reach today (prod logs + read-only queries, Oct 19)

| Supplier | 6 AM import items | Active catalog | Weekly full crawl | In-use items (on any list) | In-use items with any read today | Stock read in the morning? | Flagged out now |
|---|---|---|---|---|---|---|---|
| Chef's Warehouse | 1,025 (6%) | 15,857 | Sun, **broken on some logins** (512 vs 13,876) | 644 | 463 | Yes, up-only | 46 |
| Sysco | 8,402 (46%), 20 min | 18,247 | none | 586 | 575 | Yes, up-only | 27 |
| Premiere Produce | 2,317 (~100%), 9 s | 2,318 | Tue (Oct 6: 2,321) | 339 | 337 | Yes, up-only (for tomorrow's delivery) | 2 |
| What Chefs Want | 3,398 (49%), 2 min | 6,997 | Mon, consistent (~6,400, 7 min) | 310 | 306 | **No** | 35 |
| Performance | 3,405 (99%), 3 min | 3,433 | none | 221 | 218 | **No** | 20 |
| US Foods | 7,565 (75%), 3 min | 10,076 | n/a (daily is the full Coveo list) | 800 | 715 | **No, anywhere** | 8 |

"Any read today" means the 6 AM import or the 8 AM guide sync touched the row. For US Foods, WCW and Performance that touch carries no stock from the catalog. "Flagged out now" comes from the 8 AM guide sync only (or older values).

### Where each supplier's stock lives (code read by three sub-agents; top claims re-checked)

| Supplier | Best one-login source | Calls/day | Definite "out" | Not trustworthy | Readiness |
|---|---|---|---|---|---|
| Premiere Produce | Availability list (`getVariantPackInfoList`): the whole catalog in 1 call, plus the catalog call | 2 | `availability_status == 'OUT_OF_STOCK'` | Any other status, a missing entry, a failed call | **Ready**, after fixes below |
| Sysco | SearchProducts already returns `stockIndicator` for ~8.4k items each morning; batch-search the in-use SKUs it misses | +~30 | `stockIndicator == 'O'`, `isPhasedOut`, `isOrderable == false` | Missing indicator (today defaults to "in") | **Near-ready**: confirm what the indicator values mean |
| Chef's Warehouse | Full category crawl (`variant.inStock` count) | ~300 pages, ~17 min | Count exactly 0 | Missing count | **Blocked**: some logins only get page 1 |
| What Chefs Want | Full browse crawl daily (works weekly today, ~140 pages, ~7 min); it already returns `unavailable(location)` and `isOutOfStock(location, date)` | ~140 pages | `unavailable == true`; `isOutOfStock` only with WCW's real delivery date | `isOutOfStock` on our guessed date (flagged everything in March, fcf11a8) | **Needs a probe** (real delivery date) |
| Performance | Guide and search carry `IsOutOfStock`; a bulk source is unknown (the prices call takes 50 SKUs, stock unconfirmed) | ≤221 single-SKU searches, or ~5 if prices carry it | `IsOutOfStock == true` (seen live Sep 8) | nil, item missing from search | **Needs probes**; stock may differ by operating company (Alfio has 3) |
| US Foods | **None known before ordering.** The login already holds an `usf-inventory` scope (`us_foods_api.rb:22`) that no code uses | unknown | Today only after submit (reserved = 0) | `product.present?`, 1106 (one account only), missing from search | **Needs recon**: find the inventory endpoint |

### Silent failures found while mapping (same pattern as everything else today)

- **Premiere Produce:** if the availability call fails, every item becomes "in stock" (`premiere_produce_one_scraper.rb:202`; `graphql` returns nil on any error). The import asks about tomorrow at a fixed `04:00Z`, which turns into "today" after daylight saving ends Nov 1 (inferred). Tomorrow may not even be a delivery day.
- **US Foods:**
  - The catalog run never refreshes its 1-hour token mid-run; after expiry every call returns nil, silently.
  - A product discontinued after 3 misses and later seen again stays `in_stock: false` forever (the catalog sends nil, and nil preserves).
- **What Chefs Want:** an HTTP or GraphQL error reads as "empty page", so a category ends early with no error. The supplier's `count` is never compared with what we fetched.
- **Sysco:** search errors skip a term; a price error returns `{}`; SKUs past the 5,000 seller-discovery budget are neither priced nor flagged.

### The plan

**A. Shared foundation (built once, all six suppliers)**
1. **Record the evidence** on the one shared row per item: the raw supplier value (`stock_signal`, e.g. "0.0", "O", "OUT_OF_STOCK", "unavailable"), `stock_checked_at`, and which login and run read it. This answers "what did the supplier say this morning". No new rows.
2. **Per-supplier rule:** each scraper maps its raw value to in / out / unknown. The importer writes "out" only on a definite out, "in" only on a definite in, and nothing on unknown. This replaces the blanket "only mark in" rule (042aa34), turned on supplier by supplier.
3. **Failures mean unknown, never "in".** That fixes Premiere Produce's silent upgrade. Detect short crawls (the supplier's own total vs what we fetched), and log which login ran.
4. **Shadow first:** each supplier records signals and "would flip" counts for two mornings without changing `in_stock`. I spot-check against the supplier's site, then it's switched on.
5. **Morning stock report:** per supplier, how many in-use items were checked this morning, how many are out, and any failure. **Email Carmin only on failure, a short run, or no run** (quiet success). The Operations page shows the same numbers.

**B. Suppliers, in order of readiness**
1. Premiere Produce and Sysco: the data is already fetched, it's a few extra calls, and the rule is clear.
2. Chef's Warehouse (after the login-paging fix) and What Chefs Want (daily crawl, real delivery date).
3. Performance and US Foods, after the probes below.

**C. Read-only probes to run first** (they read from suppliers; the only write is refreshed login tokens in our own DB)
1. **CW:** browse with a "short" login vs Nate's, comparing CW's `total` and page token.
2. **Sysco:** tally the `stockIndicator` / `stockStatus` values for the 586 in-use SKUs, and cross-check them against the guide's `isAvailable`.
3. **Premiere Produce:** the distinct `availability_status` values; tomorrow vs a non-delivery day; the entry count vs the catalog size.
4. **WCW:** browse two categories with the next weekday vs a real delivery date, and compare against an item the WCW site shows as out.
5. **Performance:** dump every key from the prices call and from `search_catalog` for a known out-of-stock SKU; compare Alfio's three operating-company logins.
6. **US Foods:** find the endpoint behind the `usf-inventory` scope (the US Foods app's out-of-stock product page), and dump all keys from the product, price and list calls for a known out-of-stock SKU.
- **Not used**, because they change saved login context: PPO `select_restaurant!`, USF `switch_customer!`.

**Ordering impact**
- **No cart or submit gate changes.**
- **Chef's Warehouse, What Chefs Want, Sysco, Performance** ("supplier decides" at pre-validation): only what chefs see changes. That covers the "Out of stock" labels, the review-page warning, and the builder's cheapest/default supplier, split-order and minimum suggestions skipping out-of-stock items.
- **US Foods and Premiere Produce** have no cart line check, so pre-validation **blocks the order** on a cached "out" ("… is out of stock (cached data)", `pre_order_validation_service.rb:112-120`). Turning their morning "out" on means a morning snapshot can stop an order. Premiere Produce's is also for tomorrow's delivery only. **This needs Carmin's decision.**

**Scale:** one login per supplier (per division if stock differs, to be confirmed for Performance and US Foods). Calls and writes grow with catalog items, not restaurants: about 2 + 30 + 300 + 140 + ≤221 + unknown requests per morning.

## 9. Live probe results (Oct 19, ~2:45-3:15 PM ET)

These were meant to be read-only: no carts, no restaurant or customer switching, no drafts. **One exception happened; see the US Foods incident below.**

| Supplier | What the supplier actually returns | Same across restaurants? | Usable "out" signal | Extra calls |
|---|---|---|---|---|
| **Chef's Warehouse** | `variant.inStock` count on every category-browse item. The page token is **intermittently missing on any login** (Nate's was fine Oct 11 and missing today; Cody's and Sky's the reverse), but **page-number paging works on every login**: page 2 returned 50 new items each time. | **Yes**: 100 Produce items had identical counts on D'oro, Noche and alfios ship-tos | count == 0 | ~300 pages/day, paging by number up to CW's `total` |
| **Premiere Produce** | `availability_status` is **nil for 2,291 items and `SPECIAL_ORDER` for 21; zero `OUT_OF_STOCK`**, for Tue, Wed and Sun alike | Yes (alfios = Noche; Alfio's D'oro login currently sits on the alfios restaurant, so it wasn't a real D'oro comparison) | **None observed.** PPO doesn't report out-of-stock through this call today | n/a |
| **What Chefs Want** | Browse and guide return `isOutOfStock` and `unavailable`: **0 true** across 101 browse items (3 dates) and all 302 guide entries | Yes (alfios = Noche) | `unavailable == true` (none seen today) | ~140 pages/day |
| **Performance** | Search returns `IsOutOfStock`, matching our flags 7 for 7. The 50-SKU price call has **no stock fields** | Yes, but **all four Performance logins have one customer, AJM D'ORO RESTAURANT (33902404)**, including cjmoutinho3's login that EnPlace attaches to **alfios** | `IsOutOfStock == true` | 0: read it from the existing 6 AM catalog search (99% coverage) |
| **Sysco** | `stockIndicator` S (stocked), D (demand/special order), R/N (remote), all orderable; **no `O` seen**; `stockStatus` empty. **All 27 in-use items we show as out are not returned by Sysco search at all** (unlisted, not temporarily out) | Single login (site 019) | `O` unconfirmed; **`D` must not count as out** | n/a until an `O` is seen |
| **US Foods** | **Products v2 (already called every morning, 50/call) has an `inventory` block: `casesOnHand`, `casesOnReserve`, `casesWaitlistReserve`, `eachOnHand`, `productType`, updated live** (e.g. 5034236: 14 on hand, 2 reserved, updated 2:31 PM). The `usf-inventory` scope is the restaurant's own inventory-count tool, not supplier stock | Division 1103 for all three restaurants | On hand minus reserve ≤ 0, for regular items (`productType` R); other types to verify | 0: read it from the existing 6 AM products calls |

### Stale "out of stock" flags (active items, prod, Oct 19)

| Supplier | Flagged out | On a list | Oldest flag | Cause |
|---|---|---|---|---|
| What Chefs Want | **1,492** | 35 | Jul 6 | Not clearable. WCW says 0 out today; the catalog sends nil and the import can only mark items in. Three samples we show as out are available on WCW. |
| Chef's Warehouse | 652 | 46 | Apr 28 | Only guide items get rechecked |
| US Foods | 242 | 8 | refreshed today | Discontinue-then-reinstate leaves out; `product.present?` |
| Sysco | 189 | 27 | Sep 27 | Unlisted items, not out |
| Performance | 53 | 17 | Oct 17 | Matches PFG today (spot check 7/7) |
| Premiere Produce | 0 | 0 | | |

Stale "out" flags hide items from the add-item search (`orders_controller.rb:578`), skip them as cheapest/default supplier and in suggestions, and show "Out of stock" labels.

### Found along the way, outside stock

- **Performance order 335** (Sep, location alfios, confirmation 1296579) would have gone through cjmoutinho3's login. That login's only Performance customer is **AJM D'ORO RESTAURANT**, so that "alfios" order was placed on D'oro's account (inferred from which login serves location 9). Needs Carmin.

### Incident: a write on Alfio's US Foods account during the probes

Guessing at an inventory endpoint, I sent `POST /inventory-domain-api/v1/inventory {productNumbers:[4336327]}` with Alfio's US Foods login (cred 75). It **created** an empty inventory-count worksheet on customer 80998842:
- `inventoryId 37fc5cbb-3e27-4fe3-92c7-e6f76fbe067a`, status IN_PROGRESS, no name, 0 products, created 2026-10-19 19:10:32 UTC, shown as created by Alfio Gulisano (ALFIOSSOUS).

It is US Foods' restaurant inventory-count tool, separate from carts and orders, and nothing else was changed. **Removed 2026-10-19 ~3:25 PM ET with Carmin's OK**, using the exact call the US Foods app uses (`DELETE /inventory-domain-api/v1/inventory?inventoryId=…`, found in its public `main.427da6573e9691ac.js`, handler `deleteInventory$`). Checked first (blank, IN_PROGRESS, created 19:10:32Z, customer 80998842), deleted only that id (200), and verified only "ALFIO'S INVENTORY" remains. Lesson: never POST to a guessed endpoint during a read-only probe.
