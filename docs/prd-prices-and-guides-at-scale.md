# PRD: Prices and guides at scale (no scheduled per-restaurant reads)

**Date:** 2026-10-20 · **Status:** design for Carmin's review. Nothing built. · **Order placement:** phases 2 and 3 touch what chefs see and choose before ordering, and phase 3 touches checkout. Each phase states its impact and needs its own approval before code.

## Why

Today the 8 AM job (`SyncAllListsJob`) reads every supplier guide for every restaurant group, every morning: one login per supplier per organization. At about 4.5 supplier logins per restaurant, that's about 22,500 guide reads every morning at 5,000 restaurants. They all leave from one Railway address, which risks suppliers rate-limiting or blocking us long before the bill matters. Making that line faster (`fix-morning-sync-at-scale.md`) helps until about 250 restaurants. Past that, the shape itself is wrong.

What the daily guide read is for, and what replaces it:

| The daily read gives | Replaced by |
|---|---|
| Which items are on the restaurant's guide | The first import seeds the matched list; after that, the restaurant's own EnPlace order lists |
| The account's own prices | A morning baseline, corrected by each cart price check (decision 6) |
| Stock at What Chefs Want, Premiere Produce, Performance (only the guide read gets it today) | The morning catalog run reads stock for every listed item |
| Prices for items only that account can buy (US Foods proprietary, Sysco third-party sellers) | Live account prices when a chef orders |
| The Sept 4 "Supplier" order lists, re-copied from the guide every morning | Re-copied only on a manual refresh |

## Decisions (Carmin, Oct 20 2026)

1. **The supplier guide import exists to seed the matched list.** Keeping it in sync day to day is "completely secondary". Chefs build their own EnPlace order lists, which replace the supplier lists.
2. **A manual refresh is enough.** No scheduled re-reads of a restaurant's guide, daily or weekly.
3. **Displayed prices within about 10% are acceptable, as long as checkout confirms the actual price** (memory: display price tolerance).
4. **Group catalogs by the supplier's own warehouse, not by time zone.** Time zone only decides *when* each warehouse's run happens.
5. **For Chef's Warehouse piece-sold items, the case price and the piece price always go in their own fields.** `current_price` is the case: the piece price × pieces per case, e.g. $2.63 × 12 = $31.56. `piece_price` is the piece, as Chef's Warehouse quotes it ($2.63). Every writer follows this rule. Today both writers put the piece price in the case field, so it flips weekly (`fix-compounding-piece-prices.md`).
6. **The stored price is the last one observed.** When a chef's cart price check finds a different price, it replaces the stored one. It stays until another check or the morning run sees a different price. There's no freshness window and no separate per-account price store. Accepted consequence: at US Foods and Premiere Produce, the stored price reflects whichever account checked it last, typically within the ~10% tolerance.

## Measured: do suppliers charge each account differently?

Read-only production query, Oct 20. It compared guides synced that morning, grouped by supplier account (the login plus the restaurant chosen on it), with the test organizations 6 and 11 left out.

| Supplier | Items on 2+ accounts | Price differs | Typical gap |
|---|---|---|---|
| Chef's Warehouse | 74 | 2 (3%) | small |
| What Chefs Want | 114 | 5 (4%) | 2.8% |
| US Foods | 43 | 41 (95%) | 7.5% (max 73%) |
| Premiere Produce | 160 | 54 (34%) | 12.4%; its prices depend on the delivery date, which may explain part of this |
| Sysco, Performance | one account each | — | — |

So a single stored price is right almost everywhere for Chef's Warehouse and What Chefs Want. For US Foods and Premiere Produce it's usually within tolerance, and cart price checks keep correcting it (decision 6).

Almost every real account here belongs to Alfio's restaurants, so a new customer with its own contracts could differ more. Checkout still confirms each account's real price.

## Target design

| What | When | Scales with |
|---|---|---|
| Import a supplier guide and seed the matched list | When a restaurant connects a supplier (`ValidateCredentialsJob`, and `AutoLinkSupplierRestaurantsJob` for a newly linked restaurant) | New connections |
| Re-import a guide | Only when someone presses refresh (the existing Sync buttons) | Presses |
| Baseline price and stock for every item on any list | Each morning: one catalog run per supplier per warehouse | Suppliers × warehouses |
| Correct a stored price | When a chef's cart price check finds a different price; it replaces the stored one (decision 6) | Orders |
| The real price | Checkout confirms, as today | Orders |

## Phases

### Phase 1: the morning run prices every listed item (prerequisite)

**First step: case and piece prices in their own fields (decision 5).** For "Piece" packs, two writers set the price, and both need to follow the rule:
- **The Wednesday re-price** (`ChefsWarehouseScraper#catalog_prices`, used by `ChefsWarehouseCatalogPricingJob`)
- **The guide pricing** (`ChefsWarehouseScraper#enrich_products_with_api_prices`, then `ImportSupplierListsService#refresh_linked_product`)

Each must store the piece price in `piece_price` and the case price in `current_price`. Today both put the piece price in the main price slot and leave `piece_price` empty when the two are equal.

- **Existing rows:** fixed by code on the next run, not by hand.
- **Ordering impact:** the checkout price check compares a piece-ordered line against `piece_price` and a case line against the case price (`OrderItem#current_supplier_unit_price`). After this change, piece lines are checked against a real piece price instead of falling back to the case field.
- **Before code:** needs its own small plan and Carmin's approval.

**Gap today** (`morning-jobs-audit.md`, Oct 19). Share of each supplier's catalog the morning run prices:

| Supplier | Priced each morning |
|---|---|
| Chef's Warehouse | about 6%; the rest by the Wednesday re-price |
| What Chefs Want | about half |
| Sysco | about half, plus its known-item refresh |
| US Foods | about 75% |
| Performance | about 99% |
| Premiere Produce | all of it |

The daily guide read hides these gaps today.

**Change:** after each supplier's crawl, add a pass over **items on any list** (supplier products linked to a guide line or an order-list line) that the crawl didn't price. It looks them up by item number in batches, the way `read_stock_for_unread_list_items!` already does for Sysco stock. Batch sizes per call: US Foods `fetch_prices`, Chef's Warehouse `catalog_prices` (10 items), Performance `fetch_prices` (50), Premiere Produce (the whole catalog in 1 call), Sysco item-number search (20).

**Stock in the same pass:**
- **Premiere Produce:** its availability list covers the whole catalog in one call. Ready.
- **What Chefs Want:** `unavailable(location)` needs WCW's real delivery date. Needs a read-only probe.
- **Performance:** `IsOutOfStock`; the bulk source is unconfirmed. Needs a read-only probe.

**Also:** the 6 AM price copy (`ImportSupplierProductsService#sync_prices_to_list_items`) stays, because it's how guide lines get the baseline. But it writes one row at a time and loads every linked line into memory, so it needs a bulk update for scale.

**Ordering impact:** baseline prices and stock flags chefs see. No change to submit.

### Phase 2: cart price checks keep the stored price current (decision 6)

This mostly exists already. When a chef's cart is checked, `VerifyItemPriceJob` fetches the account's live price through the supplier's API (all six suppliers, no browser). When a case line's price differs, it writes it back to the stored price (`SupplierProduct#update_price!`, `verify_item_price_job.rb:69`). That value stays until another check or the morning run sees a different price.

**Changes:**
- **Piece lines:** today they're skipped (`uom != "PC"`). After phase 1's first step, a piece line's differing price writes `piece_price` (decision 5).
- **Supplier load:** cap concurrent price checks per supplier for the Sunday-evening rush.

(Rejected Oct 20: fetching every connected supplier's prices when a chef opens an order, and keeping a separate per-account price store with a freshness window. Carmin: the last observed price is enough, so neither is needed.)

**Ordering impact:** the price check already runs on this path. The only change is that piece prices get saved too.

### Phase 3: checkout never skips the confirmation

Today `PriceVerificationService` **skips** the check for US Foods and Premiere Produce when their login has lapsed ("Using last imported prices"). Change it to ask the chef for the code, using the existing two-factor flow, then confirm.

**Ordering impact:** direct, on the checkout path. It needs its own plan and approval (zero tolerance for fragility; see the order-safety work).

### Phase 4: turn off the daily 8 AM guide sync

Once phases 1–3 are live and verified:
- Remove `sync_all_lists` from `config/recurring.yml`.
- Delete its orphaned row from `solid_queue_recurring_tasks`. Solid Queue keeps rows after they leave the file.
- Keep `SyncAllListsJob` itself for an admin "sync everything".
- The Sept 4 Supplier lists then re-copy only on a manual refresh.
- The 9:15 morning stock report keeps working unchanged: the phase 1 pass is what reads listed items now.

**Ordering impact:** guides stop changing on their own. That's intended (decision 1).

### Phase 5: one catalog per supplier warehouse (before the first restaurant outside Cincinnati)

- **The model change:** `supplier_products` is one national copy per supplier, keyed on supplier and item number, imported through one Cincinnati login. Add a warehouse dimension: US Foods division, Sysco site or operating company, Performance operating company; Chef's Warehouse, What Chefs Want and Premiere Produce are single-region today.
- **The run:** each warehouse gets its own morning run with a login from that warehouse, scheduled around 4 AM local time: Eastern first, then Central, Mountain, Pacific. That also spreads traffic across the night.
- **Size:** the largest piece. Until it lands, everyone is on the Cincinnati catalog, which is correct while every client is in the tri-state area (memory: regional catalog risk).

## Scale, roughly (estimates, not measured)

| At 5,000 restaurants | Today's design | Target |
|---|---|---|
| Scheduled per-restaurant guide reads | about 22,500 every morning | 0 |
| Morning catalog runs | 6 | 6 × the number of warehouses (for example, 15 regions = 90), spread overnight |
| Cart price checks | Already run on every order | Unchanged: they scale with orders (about 1–2 per restaurant per supplier per week today, from one customer's history), spread across the day |

## Considered and rejected

- **Weekly guide reads:** they add nothing once the guide lives in EnPlace (decision 2).
- **Reading every guide every morning:** doesn't scale, and concentrates supplier traffic at 8 AM from one address.
- **A catalog import per account:** what Sysco did per login (about 20 minutes each). Removed on the morning-sync branch.
- **Grouping by time zone:** two restaurants in one state can be on different warehouses. Time zone only schedules.
- **Estimating account prices from a learned discount:** contract prices are per item, not one factor per account. Display tolerance plus cart price checks make it unnecessary.

## Open questions

1. Read-only probes for batch stock at What Chefs Want (delivery date) and Performance.
2. Per-supplier limits on concurrent price checks at peak. To be sized from order timestamps when phase 2 is planned.

Resolved Oct 20:
- **The meaning of a Chef's Warehouse piece-sold price:** both prices are stored, each in its own field (decision 5).
- **A freshness window for account prices:** not needed. The last observed price stays (decision 6).
- **How often a US Foods login needs the chef's code:** about once a month, from Carmin's experience (not measured). So phase 3's "ask for the code instead of skipping" hits a given login at most about monthly.

## Relation to work already built (not shipped)

- **`morning-sync-and-performance-refresh`:** guide-only Sysco sync, per-supplier lanes, `list_sync` worker. It's the bridge until phase 4, and it makes the first import and manual refresh fast. Ship it.
- **`claude/reverent-newton-54aa4b`:** order safety. Needed regardless.
- **`fix-compounding-piece-prices`:** stops a missed guide price inflating the catalog row. Phase 1 builds on correct catalog prices.
