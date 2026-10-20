# PRD: Prices and guides at scale (per-restaurant prices, no scheduled guide reads)

**Date:** 2026-10-20, revised the same day after the chef's input on rep special prices · **Status:** design for Carmin's review. Nothing built. · **Order placement:** phases 1–4 change the prices chefs see and compare, and phase 5 changes checkout. Each phase states its impact and needs its own approval before code.

## Why

**Today, the morning guide read doesn't scale.** The 8 AM job (`SyncAllListsJob`) reads every supplier guide for every restaurant group, every morning. At about 4.5 supplier logins per restaurant, that's about 22,500 full guide reads every morning at 5,000 restaurants. They all leave from one Railway address, so suppliers would likely rate-limit or block us long before the bill matters. `fix-morning-sync-at-scale.md` buys time until about 250 restaurants.

**One shared price per supplier isn't enough either.** The first version of this design assumed one morning catalog price per supplier would do. **Carmin's chef corrected that (Oct 20):** a supplier rep can lower the price of specific items on *one* restaurant's guide, for example "you aren't buying enough of our cheese, I'll cut your cheese price". These special prices are per restaurant and per item. They change whenever a rep decides, and can be far more than the ~10% display tolerance. Production agrees: at US Foods, 41 of 43 items on more than one account had different prices.

The fix is that **prices stay per restaurant, but reading them gets cheap.** A special price only matters for the items that restaurant buys, a few hundred per supplier. Reading prices for known items takes a handful of batch calls, while re-reading a whole guide takes many more, and only the first import needs the guide's contents.

What the daily guide read gives today, and what replaces it:

| The daily read gives | Replaced by |
|---|---|
| Which items are on the restaurant's guide | The first import seeds the matched list; after that, the restaurant's own EnPlace order lists |
| **The restaurant's own prices, specials included** | A **price-only** read of its listed items (phase 3), live prices when a chef opens an order (phase 4), and checkout prices. All are kept on the restaurant's own lines (phase 1). |
| Stock at What Chefs Want, Premiere Produce, Performance (only the guide read gets it today) | The morning catalog run reads stock for every listed item (phase 2) |
| The Sept 4 "Supplier" order lists, re-copied from the guide every morning | Re-copied only on a manual refresh |

## Decisions (Carmin, Oct 20 2026)

1. **The supplier guide import exists to seed the matched list.** Keeping its contents in sync day to day is "completely secondary". Chefs build their own EnPlace order lists, which replace the supplier lists.
2. **A manual refresh is enough for guide contents.** No scheduled re-reads of a restaurant's guide contents. (Prices are separate: decision 7.)
3. **Displayed prices within about 10% are acceptable, as long as checkout confirms the actual price.** This applies where a restaurant has no price of its own (memory: display price tolerance).
4. **Group catalogs by the supplier's own warehouse, not by time zone.** Time zone only decides *when* each warehouse's run happens.
5. **For Chef's Warehouse piece-sold items, the case price and the piece price always go in their own fields.**
   - `current_price` is the case: the piece price × pieces per case, e.g. $2.63 × 12 = $31.56.
   - `piece_price` is the piece, as Chef's Warehouse quotes it ($2.63).
   - Every writer follows this rule. Today both writers put the piece price in the case field (`fix-compounding-piece-prices.md`).
6. **A restaurant's stored price is the last one observed for that restaurant.** It's revised from the first version, which was the last price seen by anyone, in the shared row. When a price read or a cart check finds a different price for a restaurant, that price goes on **that restaurant's own lines** for the item. It stays until the next read or check for that restaurant. The shared catalog row is the baseline only, and one restaurant's deal never shows for another.
7. **Restaurants' special prices are real and must be kept.** Prices for each restaurant's listed items are refreshed per restaurant, prices only:
   - **Daily, while EnPlace is small.**
   - **At scale:** a rotation through the week, plus a nightly check of each restaurant's most-ordered items (phase 3).

## Measured: do suppliers charge each account differently?

Read-only production query, Oct 20. It compared guides synced that morning, grouped by supplier account (the login plus the restaurant chosen on it), with the test organizations 6 and 11 left out.

| Supplier | Items on 2+ accounts | Price differs | Typical gap |
|---|---|---|---|
| Chef's Warehouse | 74 | 2 (3%) | small |
| What Chefs Want | 114 | 5 (4%) | 2.8% |
| US Foods | 43 | 41 (95%) | 7.5% (max 73%) |
| Premiere Produce | 160 | 54 (34%) | 12.4%; its prices depend on the delivery date, which may explain part of this |
| Sysco, Performance | one account each | — | — |

US Foods' 95% fits contract and rep pricing. Almost every real account here belongs to Alfio's restaurants, so a new customer with its own contracts could differ more.

## Where prices live (already per restaurant)

- **The order builder already compares each restaurant's own guide-line price.** It uses `SupplierListItem.price`, falling back to the shared catalog price only when the line has none (`ProductMatch#prices_by_supplier`, `product_match.rb:259`). Each restaurant's lists, and so its lines, are its own.
- **Two writers break this today:**
  1. **The 6 AM catalog import** (`ImportSupplierProductsService#sync_prices_to_list_items`) copies the importing login's price onto **every** restaurant's lines. That replaces specials until each restaurant's next guide sync.
  2. **The checkout price check** (`VerifyItemPriceJob` → `SupplierProduct#update_price!`, `verify_item_price_job.rb:69`) writes one restaurant's price into the **shared** catalog row. The next import then copies that row onto everyone's lines.

## Target design

| What | When | Scales with |
|---|---|---|
| Import a supplier guide and seed the matched list | When a restaurant connects a supplier (`ValidateCredentialsJob`, and `AutoLinkSupplierRestaurantsJob` for a newly linked restaurant) | New connections |
| Re-import a guide's contents | Only when someone presses refresh (the existing Sync buttons) | Presses |
| Baseline price and stock for every item on any list | Each morning: one catalog run per supplier per warehouse, into the shared catalog row | Suppliers × warehouses |
| The restaurant's own prices for its listed items | Price-only read. Daily while small; at scale, a weekly rotation plus a nightly check of its top items | Restaurants (light) |
| Prices for an order's items | When a chef opens an order, across their connected suppliers | Orders |
| The real price | Checkout confirms, as today, and saves it to that restaurant's lines | Orders |

## Phases

### Phase 1: keep restaurants' prices on their own lines (small; do first)

1. **Mark which line prices are the restaurant's own.** Add `account_price_at` (or similar) to `supplier_list_items`. Its own guide read, price read, open-order fetch or checkout check sets it. The 6 AM copy doesn't.
2. **The 6 AM copy only fills gaps.** `sync_prices_to_list_items` writes the catalog price only to lines with no price of their own (or an account price older than an agreed age). It also becomes a bulk update: today it's one `UPDATE` per line, and it loads every linked line into memory.
3. **Checkout prices go to the restaurant.** `VerifyItemPriceJob` saves a differing price to that restaurant's lines for the item, instead of the shared row. With decision 5 in place, piece lines save `piece_price` too (today they're skipped: `uom != "PC"`).
4. **Ordering impact:** `VerifyItemPriceJob` is on the checkout path, so only where its answer is *stored* changes, never what it decides. Needs its own plan and approval.

### Phase 2: the morning run prices every listed item, for the baseline

**First step: case and piece prices in their own fields (decision 5).** For "Piece" packs, two writers set the price, and both must follow the rule:
- **The Wednesday re-price** (`ChefsWarehouseScraper#catalog_prices`, used by `ChefsWarehouseCatalogPricingJob`)
- **The guide pricing** (`ChefsWarehouseScraper#enrich_products_with_api_prices`, then `ImportSupplierListsService#refresh_linked_product`)

Existing rows are fixed by code on the next run, not by hand. The checkout price check then compares piece lines against a real piece price. Needs its own small plan.

**Gap today** (`morning-jobs-audit.md`, Oct 19). Share of each supplier's catalog the morning run prices:

| Supplier | Priced each morning |
|---|---|
| Chef's Warehouse | about 6%; the rest by the Wednesday re-price |
| What Chefs Want, Sysco | about half (Sysco plus its known-item refresh) |
| US Foods | about 75% |
| Performance, Premiere Produce | nearly all |

**Change:** after each supplier's crawl, a pass over **items on any list** that the crawl didn't price. It looks them up by item number in batches, the way `read_stock_for_unread_list_items!` already does for Sysco stock.
- A miss is retried once. Chef's Warehouse's pricing API sometimes leaves out an item, and `ChefsWarehouseApi#fetch_prices` silently skips a failed batch of 20 (`next unless response.is_a?(Array)`).
- Chef's Warehouse is asked at both warehouses (`800001`, `133002`), as `catalog_prices` already does. On Oct 20, three Chef's Warehouse guide items got no price at `800001`.

**Stock in the same pass:**
- **Premiere Produce:** one call covers the catalog. Ready.
- **What Chefs Want:** needs the real delivery date. Needs a read-only probe.
- **Performance:** the bulk source is unconfirmed. Needs a read-only probe.

**Ordering impact:** baseline prices (shown only where a restaurant has no price of its own) and stock flags. No change to submit.

### Phase 3: a price-only refresh of each restaurant's listed items

**Job:** for each restaurant login, take the supplier products on its lists and price them in batches through the scraper's existing price call (`scrape_prices`, all six suppliers, API only), then write that restaurant's lines (phase 1).
- **Cost:** roughly 10–30 calls per login, depending on list size and batch size. A full guide read costs more and also re-reads contents.
- **Where it runs:** on the existing `list_sync` worker, one lane per supplier, spread overnight in each warehouse's time zone.
- **Frequency, at scale:**
  - **Daily** while EnPlace is small: up to about 1,000 restaurants, or about 100,000 supplier calls a day.
  - **Above that:** each restaurant's full price refresh rotates through the week. Each night it also checks that restaurant's **top ~20 most-ordered items** per supplier, since a rep's deal targets what the restaurant buys. If one of those comes back different, that restaurant's full refresh for that supplier runs that night.

**Ordering impact:** the prices chefs see and compare. Checkout still confirms.

### Phase 4: prices for the order when a chef opens it

When a chef opens the order builder, the app fetches that restaurant's prices for **the items in that order** from each connected supplier. Previously rejected; it's back because of rep specials. This is where a deal decides which supplier is cheapest.
- **On the page:** it shows what's stored at once and updates rows as prices arrive. `DeliveryDatesRefresher` and `FetchSyscoDeliveryDatesJob` already work this way and are the template.
- **Storage:** prices go to the restaurant's lines (phase 1).
- **Duplicates:** the same restaurant, supplier and item aren't re-fetched within about an hour, so a chef reopening the order doesn't hit the supplier again. That's supplier load, not a display rule.
- **Limits:** cap concurrent calls per supplier for the Sunday-evening rush.
- **Lapsed logins:** if a login has lapsed, show the stored price with a note. Never block the page.

**Ordering impact:** changes which supplier looks cheapest, and therefore what chefs choose. Submit is unchanged.

### Phase 5: checkout never skips the confirmation

Today `PriceVerificationService` **skips** the check for US Foods and Premiere Produce when their login has lapsed ("Using last imported prices"). Change it to ask the chef for the code, using the existing two-factor flow, then confirm. Carmin: chefs re-enter the US Foods code about once a month, so this rarely interrupts.

**Ordering impact:** direct, on the checkout path. It needs its own plan and approval (zero tolerance for fragility; see the order-safety work).

### Phase 6: turn off the daily 8 AM guide-contents sync

Once phases 1–4 are live and verified, the price-only refresh (phase 3) has taken over the price role:
- Remove `sync_all_lists` from `config/recurring.yml`.
- Delete its orphaned row from `solid_queue_recurring_tasks`. Solid Queue keeps rows after they leave the file.
- Keep `SyncAllListsJob` itself for an admin "sync everything".
- The Sept 4 Supplier lists then re-copy only on a manual refresh.

**Ordering impact:** guide contents stop changing on their own (decision 1).

### Phase 7: one catalog per supplier warehouse (before the first restaurant outside Cincinnati)

- **The model change:** `supplier_products` is one national copy per supplier, imported through one Cincinnati login. Add a warehouse dimension: US Foods division, Sysco site or operating company, Performance operating company; Chef's Warehouse, What Chefs Want and Premiere Produce are single-region today.
- **The run:** each warehouse gets its own morning run with a login from that warehouse, around 4 AM local time.
- **Size:** the largest piece. Until it lands, everyone is on the Cincinnati catalog, which is correct while every client is in the tri-state area.

## Scale, roughly (estimates, not measured)

Assumptions: about 4.5 supplier logins per restaurant and about 20 calls per login per price refresh. Revenue is restaurants × $149 a month, before extra seats.

| Restaurants | Revenue / month | Daily price refresh (phase 3) | Verdict |
|---|---|---|---|
| ~250 | ~$37k | ~25,000 calls/day | Fine, spread overnight |
| ~1,000 | ~$149k | ~100,000 calls/day (~1 per second) | Probably fine; watch the refusal line in the 9:15 email |
| ~5,000 | ~$745k | ~450,000 calls/day | Too much from one address: switch to rotation plus top-item checks (~25,000 full refreshes a week, plus about 100,000 top-item checks a night) |

- **The load splits by supplier.** The most common supplier (US Foods today) carries the most.
- **Open-order fetches (phase 4) and checkout checks** add calls in proportion to orders, spread across the day.
- **The real ceiling is each supplier's tolerance, not the Railway bill,** and nobody knows it. Ways to raise it if needed:
  - more than one outgoing address
  - supplier deal or contract flags in their APIs, if they exist (a read-only probe)
  - partner API access from the larger suppliers

## Considered and rejected

- **One shared price per supplier for display and comparisons:** rejected Oct 20 after the chef's input. Rep specials are per restaurant.
- **Last price seen by anyone, stored in the shared row** (the first version of decision 6): it leaks one restaurant's deal to the others.
- **Weekly or daily re-reads of guide *contents*:** they add nothing once the guide lives in EnPlace (decision 2). A price-only refresh is different, and it's kept (phase 3).
- **Reading every guide every morning:** doesn't scale, and concentrates supplier traffic at 8 AM from one address.
- **A catalog import per account:** what Sysco did per login (about 20 minutes each). Removed Oct 20.
- **Grouping by time zone:** two restaurants in one state can be on different warehouses.
- **Estimating account prices from a learned discount:** contract and rep prices are per item, not one factor per account.

## Open questions

1. **How often reps change prices, and on how many items.** This sizes phase 3's rotation and top-item check. Carmin's chef or the price history can tell.
2. **Do supplier APIs flag contract or deal prices?** That would let us refresh only flagged items. Needs read-only probes, GET-only or existing price calls.
3. **Real calls per login.** List sizes and each supplier's batch size; measure during phase 3.
4. **Read-only probes for batch stock** at What Chefs Want (delivery date) and Performance.
5. **Per-supplier caps for open-order fetches and checkout checks at peak,** sized from order timestamps.

Resolved Oct 20:
- **The meaning of a Chef's Warehouse piece-sold price:** both prices are stored, each in its own field (decision 5).
- **How often a US Foods login needs the chef's code:** about once a month, from Carmin's experience.
- **Guide lines that come back without a price** (37 Chef's Warehouse, 85 US Foods on Oct 20):
  - US Foods' are discontinued or unavailable items, by design (`fix-usf-price-errors.md`).
  - Chef's Warehouse's are mostly random misses from its pricing API, plus three items not priced at warehouse `800001`.
  - They're harmless while the line falls back to the catalog price. Phase 2 retries them.

## Relation to work already shipped (Oct 20, on main)

- **`fix-morning-sync-at-scale.md`:** guide-only Sysco sync, per-supplier lanes, the `list_sync` worker. It's the bridge until phase 6. Phase 3 runs on the same worker.
- **`fix-stuck-syncing-lists.md`:** guide syncs only touch their own restaurant's lists.
- **`fix-compounding-piece-prices.md`:** a missed guide price can't inflate the catalog row.
- **`order-placement-double-submit-and-account-lock.md`:** order safety. Needed regardless.
- **`job-memory-log.md`:** finds which jobs grow worker memory. Its results come before any matching-code changes.
