# PRD: Performance Foodservice (PFG) Integration

**Branch**: `performance-integration` · **Started**: 2026-09-08 · **Status**: Phase 1–2 DONE & live-verified; Phase 3 recon captured

## Live validation result (2026-09-08)

Fresh login against real credentials succeeded in 5.7s. Confirmed:

- B2C email+password login → redirect back to CustomerFirst SPA → session persisted
  (4 cookies, 2 localStorage, 10 sessionStorage MSAL entries).
- `PerformanceApi#restore_session` extracts a usable bearer token from the MSAL cache:
  not expired, `scp: customer-first-site-api`, `aud: 8ff5c07b-01b7-43ac-8c95-8301171912a8`
  (the API app registration; SPA client is `c68e7fae-...`). **Token-only API access works
  — no browser needed after initial login.**
- Customer context: account is keyed by **CustomerId GUID
  `bbddf26a-24ea-40c1-a4a2-b6721b073f9b`** (PFG's equivalent of USF division/customer
  numbers). Comes from `Site/V1/GetCurrentUserSite`; claims also carry `oid`/`sub`/`tid`.

### Live middleware routes observed (28 calls during login) — phase 3+ targets

- Catalog/search: `TypeAhead/V1/GetTypeAhead?SearchValue=&BusinessUnitKey=0&CustomerId=…`
- Lists / order guides: `ProductListNotification/V1/GetProductListNotificationTotal`,
  `OrderEntryHeader/V1/GetCustomersOrderEntryHeaders` (POST)
- Ordering (phase 7, untouched): `OrderEntryHeader/V1/GetActiveOrder`, `Order/V1/GetOrder`,
  `Customer/V1/GetCustomerDeliveryDates`, `OperationCompanyOrderType/V1/GetCustomerOperationCompanyOrderTypes`
- Account: `AccountReceivable/V1/GetAccountReceivableBalance`, `Delivery/V1/GetDeliveries`

## Phase 3 (catalog import) — DONE & live-verified 2026-09-08

Pure API, no browser (mirrors UsFoodsApi). Two-call pattern:
- `POST ProductCatalog/V1/SearchProductCatalog` — products, paginated
  (`CurrentPageNumber`/`Skip`/`PageSize`), `LoadPricing:false`. Real pagination
  confirmed (page 0/1 zero SKU overlap). `NumberOfPages` caps at 100.
- `POST CustomerProductPrice/V1/GetOrderEntryCustomerProductPrice` — customer
  prices keyed by ProductKey, batched 50.

Both need account context (`PerformanceApi#account_context`, memoized):
`OperationCompanyNumber` (e.g. "790") from `Site/V1/GetCurrentUserSite`
→ `UserCustomers[0]`; `OrderEntryHeaderId` + `DeliveryDate` from
`OrderEntryHeader/V1/GetActiveOrder`.

Field mapping (`format_catalog_product`): ProductNumber→sku,
ProductBrand+ProductDescription→name, PackSize+UOM abbrev→pack_size,
ProductCategory→category, ShoppingCategory→subcategory,
ProductImageUrlThumbnail→image (long-lived SAS token), IsOutOfStock ignored
(catalog never sets stock — order guide is authoritative).

**CRITICAL — catch-weight pricing.** For a catch-weight case UOM, PFG's `Price`
is PER POUND, not per case. The **UOM-level** `ProductIsCatchWeight` flag is
authoritative (the top-level flag is always false). Case price =
`Price × ProductAverageWeight`. Verified live: $1.64/lb × 39 = $63.96,
$1.60/lb × 58.71 = $93.94, salmon $5.51/lb × 20 = $110.20. Storing the raw
per-lb price made cases read ~40x too cheap and would corrupt savings. Fixed +
regression-specced. Live import of 5 terms → 397 products, all prices sane
(only sub-$5 item is a genuine $0.01 dispenser).

## Phase 5 (order guides / lists) — DONE & live-verified 2026-09-08

Pure API. `GetProductListHeaders` → guides; the real items call is
**`POST ProductListSearch/V1/SearchProductList`** (body: CustomerId,
ProductListHeaderId, QueryText:"", SortByType, IncludeRecipeItems). NOTE the
header's `ProductListDetailCount` is unreliable (read 0 for a guide that has 11
items — do not trust it). Response nests items as
`ResultObject.ProductListCategories[].Products[].Product`, each `Product` in the
SAME CatalogProduct shape as phase 3, so name/pack/catch-weight logic is shared
(`case_price_for`, `product_display_name`, `product_pack_size`). Prices merged via
`fetch_prices`. Zero-GUID system list is skipped; a guide returning 0 items is
skipped (not synced empty — WCW regression guard).

Live: "alfios" (`225278a5-…`, type 3) → 11 items imported, all linked to catalog
SupplierProducts, sync_status synced. Out-of-stock flags honored (truffle oil,
mascarpone). Canonical Product links are 0/11 at this stage — that's phase 6
(matching), a separate step.

## Phase 7 (ordering) — Stage A framework only, NOT live-verified

Built behind two independent gates; NO order was ever placed and no write ever
reached PFG during development.

Order model: the PFG cart IS the customer's real draft `OrderEntryHeader`.
Add-to-cart = `OrderEntryDetail/V1/UpdateOrderEntryDetail` (write); submit =
`OrderEntryHeader/V1/SubmitOrderEntryHeader` (point of no return); reads via
`GetActiveOrder` / `GetOrder`.

Scraper surface (consumed by OrderPlacementService): `add_to_cart`, `clear_cart`,
`verify_cart_matches!` (fails CLOSED — CW phantom-cart lesson), `checkout(dry_run:)`.

**Gates:**
1. `cart_writes_enabled?` = `ENV['PERFORMANCE_CART_WRITES']=='true'`, default OFF.
   While OFF: add_to_cart/clear_cart make ZERO writes (log-and-simulate),
   verify_cart_matches! skips (nothing was written), and checkout REFUSES a live
   submit. This is the authoritative gate and holds even in production (where
   `checkout_enabled` seeds true) — so PFG ordering fails closed until explicitly
   enabled. Nothing is orderable for real yet.
2. `checkout(dry_run:)` — OrderPlacementService forces dry_run in non-prod.

**UNVERIFIED (Stage B/C):** the UpdateOrderEntryDetail / SubmitOrderEntryHeader
request shapes and the draft's line-item response shape (`order_lines`) are
inferred from the bundle + empty-draft recon — never exercised live (the account
has no test order to place). Stage B = one supervised, reversible cart write
(add → read back → remove, no submit) to confirm the shapes. Stage C (submit)
needs a real order.

Risks captured (see session notes): cart reconciliation must stay fail-closed;
catch-weight items bill on actual weight so totals are estimates; delivery
date/cutoff may block submit on this account ("not set up for deliveries");
single shared draft = concurrency hazard; retry idempotency; PlaceOrderJob bare
rescue.

## Robustness fix + price/validation helpers (2026-09-24)

**Catalog/list/price broke with no open draft (found via a 16-day-stale session).**
Those calls thread `OrderEntryHeaderId` through the request; when the account has no
open draft (the normal resting state — drafts expire), `GetActiveOrder` returns none
and the middleware 400s with *"Product Catalog page is not available"* for nil/omitted/
empty OEH. Fix: `account_context` falls back to the **no-active-order sentinel**
`00000000-0000-0000-0000-000000000000` (what the SPA itself sends in that state), which
returns 200. Write paths (`add_to_cart`/`clear_cart`) call `require_real_draft!` and fail
loudly on the sentinel — creating a real draft (`CreateOrderEntryHeader`) is a Stage B item.

**Bucket 1 helpers (pure API, no writes):**
- `scrape_prices` — implemented (was a stub). Per SKU: `product_by_sku` (catalog lookup,
  SKU == ProductKey) + `fetch_prices`, catch-weight-corrected via `case_price_for`.
  Powers at-order price verification + the per-item verify action. Verified live
  ($1.65/lb × 39 = $64.35 case).
- `get_order_minimum` / `get_delivery_availability` — read `MinimumOrderAmount` /
  `CutoffDateTime` off the draft. Best-effort: return nil/empty when no draft is open
  (resting state), populate on a real order. Pre-validation degrades gracefully.

Also confirmed: password-auth **auto-relogin works** after session expiry (re-drove B2C
with stored credentials, status → active). Recurring jobs (staggered import, sync lists,
refresh sessions) auto-include Performance — no wiring needed.

## Stage B — cart-building VERIFIED LIVE (2026-09-24, no order placed)

Proven end-to-end: our `add_to_cart` builds a real PFG cart, `verify_cart_matches!`
passes/fails-closed, `checkout(dry_run:)` reports totals without submitting, cleanup
tears it down. A live run built chicken ×2 + tomato ×1 = **$98.82**, caught an injected
orphan line (fail-closed), and removed everything ($0). Submit was never called.

Key live findings (these replace earlier inferences):
- **Add-to-cart auto-creates the draft.** `UpdateOrderEntryDetail` with the
  no-active-order sentinel returns `IsSuccess:true` and a NEW real
  `OrderEntryHeaderId` in `ResultObject`. No separate `CreateOrderEntryHeader` call
  is needed. `add_to_cart` threads that id onto `@active_draft_id` so verify/checkout
  act on the created draft (account_context is memoized to the pre-create sentinel).
- **UpdateOrderEntryDetail needs the FULL product payload**, not just ProductKey — a
  minimal body returns `IsSuccess:true` but silently creates NO line. Required fields:
  BusinessUnitKey, BusinessUnitERPKey, CustomerId, ProductKey, UnitOfMeasureType,
  Quantity (ABSOLUTE — a set; 0 removes), Price (raw per-UOM), ProductNumber,
  ProductDescription, ProductBrand, ProductPackSize, ProductIsCatchWeight,
  ProductAverageWeight, ShipLaterMaxEstimatedDays, CutoffDateTime,
  UOMOrderQuantityAlert{Min,Max}. `add_to_cart` sources these from `product_by_sku` +
  `fetch_prices`.
- **No per-line READ endpoint exists.** GetOrder and GetOrderCart are header-only
  (line data lives client-side in the SPA). So `verify_cart_matches!` reconciles on
  GetOrder TOTALS (TotalLines == distinct SKUs, TotalQuantity == summed qty) — catches
  orphaned/extra/missing lines and qty errors; the residual it cannot catch is a
  same-count/same-qty SKU swap (bounded: we only submit what add_to_cart reported).
  `order_lines` returns [] (OPEN ITEM: find a line-read endpoint) → `clear_cart` can't
  enumerate orphans, but verify fails closed so nothing bad submits.
- This account: `MinimumOrderAmount` = $0, valid `OrderCutoffDate` present. The earlier
  "not set up for deliveries" (on GetCustomerDeliveryDates) does NOT block order-building.

Still gated: `cart_writes_enabled?` (PERFORMANCE_CART_WRITES) OFF by default; the live
verification set it only within throwaway scripts. Submit (Stage C) still needs a real
order. Remaining before live: find a line-read endpoint (or accept totals reconciliation),
and verify SubmitOrderEntryHeader with one real order.

## Production ordering enabled (2026-09-25) — supersedes the gate notes above

Carmin's call: production exists to place REAL orders, so the Stage A kill switch no
longer blocks production. `cart_writes_enabled?` = `Rails.env.production? ||
PERFORMANCE_CART_WRITES=true`:
- **Production:** Performance orders like every other supplier; the existing per-supplier
  `checkout_enabled` switch is the only gate (seeded on in prod).
- **Outside production:** cart writes stay off unless opted in. Not a blocker: dev and prod
  share the customer's REAL PFG account and PFG has no line-list read, so a dev test line
  left in the real cart would fail verify_cart_matches! on the next real prod order.

**False-success bug fixed (found pre-deploy):** the live submit path didn't check
`IsSuccess`; PFG rejects with HTTP 200 + IsSuccess:false, and the code fell back to a
fabricated `API-<timestamp>` confirmation — a rejected order would have been marked
submitted. Now: anything but IsSuccess:true raises with PFG's ErrorMessages (order →
failed, visibly); on success the confirmation is PFG's OrderNumber, else the draft's
OrderEntryHeaderId (PFG's own id), never fabricated. Full submit response is logged —
the SubmitOrderEntryHeader shape is still unverified until the first real order.
Regression-specced.

Pre-deploy review also established: no migrations in the branch; the BaseScraper
`detect_maintenance` fix has no prod effect on USF/PPO (their only caller,
`validate_cart_before_checkout`, is never called); failed orders are excluded from
reports (KPI_STATUSES = submitted/confirmed/dry_run_complete); PlaceOrderJob has no
retry (no double-submit). Known reporting effect: savings peers come from the Product
spine regardless of which suppliers a chef uses, so once PFG's catalog is in prod it
becomes a peer in every org's savings (historicals recompute at today's prices).

## Production catalog + blueprint (2026-09-25, after deploy of 7b75644)

Carmin connected Performance in prod (org 7: credential 127 at location 9 = list 8's
location; credential 128 at location 16). The connect imports (standard terms) took ~65
min each in prod vs ~2 min on dev — prod's much larger Product table makes
`find_or_create_product` slower per new product.

Full crawl: harvested-term rounds enqueued as ordinary
`ImportSupplierProductsJob.perform_later(6, [terms])` on the worker (`limits_concurrency`
serializes imports per supplier, so no races). Driven by stateless per-round commands
(terms already searched are recovered from the jobs' own arguments) after a long-lived
driver over `railway ssh` died with its session — nothing it had enqueued was affected.
Round 1 +240, round 2 +23 → converged at **3,601 products**.

`rake baseline:attach SUPPLIER=performance` (dry run, then APPLY=1): **851 attached** (73
into existing blueprint groups, 778 new cross-supplier links), 92 stale (counterpart SKU
not in prod), 127 one-per-supplier, 2 deferred (order-list reference). Prod blueprint
2,403 → 3,254 links. Verified: 0 non-PFG snapshot rows, original 2,403 links intact, 0
Products with 2+ PFG, list 8 untouched. PFG products sharing a Product with another
supplier: 159 → 921. Rollback: `rake baseline:rollback RUN_TAG=claude_baseline_performance_v1 APPLY=1`.

**OPEN — where PFG shows on the matched list:** list 8 had 14 PFG rows (12 alfios guide
items + 2 from catalog search). "Search catalog" (CatalogSearchService) only fills
UNMATCHED rows by default — 71 of list 8's 1,039 — so PFG won't appear in rows already
matched across other suppliers unless those rows are re-searched individually or catalog
search is widened to all rows (product decision: it writes catalog items into more of a
chef's list, chef-initiated).

## Full catalog + blueprint (Claude baseline) sweep — DEV (2026-09-25)

**Full catalog on dev.** Search requires text (empty/`*` queries rejected), so a
"snowball" crawl: the importer's standard terms, then rounds of unsearched words
harvested from PFG product names, until a round adds <40 SKUs. 4 rounds / 571 terms
→ **3,600 products** (3,592 priced, 3,020 with images), converged. `CATALOG_PAGE_SIZE`
raised 25→100 (verified live; 4x fewer calls — also cuts the prod daily import).
Script: `tmp/baseline_pfg/snowball_import.rb` (gitignored, local only).

**OPEN (prod) — full-catalog refresh:** the prod daily import uses only the standard
~120 terms, which reach ~1,150 of the 3,600 products. Safe (miss-tracking skips when <60%
of the catalog is seen, so nothing is falsely discontinued) but ~2/3 of PFG products
would never get fresh prices. Fix: implement `PerformanceScraper#scrape_catalog_deep`
with the snowball term-harvest so it joins the existing nightly `StaggeredDeepImportJob`
rotation (additive, reinstate-only, no miss tracking — the deep path's contract).

**Blueprint sweep** (same method + rubric as the July baseline, restricted to pairs
with Performance on one side; working files in `tmp/baseline_pfg/`, gitignored):
1. `export_catalog.rb` — read-only dev export (42,119 active SPs).
2. `block_pfg.py` — original token-IDF blocking, >4x per-unit price gate, top-6/item →
   5,231 pairs covering 1,560 of 3,600 PFG items (the rest have no counterpart —
   exclusives/house brands/categories dev's older snapshot lacks).
3. Claude (Sonnet) adjudication, `RUBRIC.md` = the July rubric verbatim + catch-weight
   caution. Pass 1 = each item's top-2 (2,691 pairs); pass 2 = next-2 for unmatched
   items (598). 3,289 decided: 1,479 match / 1,729 no_match / 81 uncertain; 0 coverage gaps.
4. `build_artifact.py` → **`db/baseline/performance_baseline_matches.json`** (committed
   artifact): best match per PFG item, high + medium only (low/uncertain never attach),
   13 medium matches dropped because their own reason hedged ("likely", "?"). Keyed by
   supplier CODE + SKU, not DB ids, so it applies to prod when PFG ships there.
   Spot-check: high matches clean; 28/30 sampled cross-brand mediums correct (the
   misses: purple rice vs purple sticky rice; deli vs Campbell's clam chowder).
5. New **`rake baseline:attach SUPPLIER=performance [APPLY=1]`** (7 specs): moves ONLY the
   new supplier's product onto the matched product's existing spine `Product`; never
   writes the counterpart or chef `product_matches`; one-per-supplier-per-Product guard;
   defers if the product's current Product is referenced by an OrderListItem; snapshots
   under `claude_baseline_performance_v1` → `rake baseline:rollback RUN_TAG=... APPLY=1`.

**Applied on dev:** 915 attached (19 into existing blueprint groups, 896 new
cross-supplier links), 146 skipped by the one-per-supplier guard, 11 stale, 0 order-list
deferrals. Dev blueprint 665 → 1,580 links; 948 PFG-shared Products now comparable.
Verified: 0 non-PFG snapshot rows, original 665 links intact, 0 Products with 2+ PFG,
chef list 8 unchanged today (its 825→813 drop was a user-initiated
`bulk_merge_duplicates` on Sep 8 15:00, not this work).

**Ordering impact (by design, same as the other suppliers' blueprint):** OrderBuilderService
is supplier-scoped (unaffected); PriceComparisonService now shows PFG; **SplitOrderService
auto-assigns each item to the cheapest connected supplier**, so PFG now wins items where
it's cheapest. Placement still gated (`PERFORMANCE_CART_WRITES` off; dev always dry-runs).

**NOT done (deliberately):** no re-run of `AiProductMatchJob` on a chef list — it
`destroy_all`s product_matches. List 8's matches are untouched; new items syncing in
join via the incremental matcher's Pass 1 (shared product link).

**For prod:** migrate/deploy, import PFG catalog in prod, then
`rake baseline:attach SUPPLIER=performance` (dry run first). Prod's blueprint is larger
(~1,100 groups) so more rows will land in existing groups.

## Incidental fix

`BaseScraper#detect_maintenance` called `.text` on `browser.body` (Ferrum returns raw
HTML String → NoMethodError). This crashed the Performance validation before it reached
the form, and was latent for every scraper calling `detect_error_conditions` (USF, PPO).
Fixed to read rendered `innerText`; regression spec in `base_scraper_spec.rb`.

---


## What

Add Performance Foodservice as the 6th supplier, via PFG's **CustomerFirst** platform
(www.customerfirstsolutions.com). Full pipeline eventually: auth → catalog → lists →
matching → ordering, in that order.

## Why CustomerFirst (and not the other two PFG platforms)

Recon (Aug 13 2026) found PFG runs THREE ordering platforms: CustomerFirst (modern
React SPA + middleware API), PerformanceNet (2018 JSP, no API, ~35 division shards),
and TRACS Direct (WebForms). Carmin's account is on CustomerFirst, so the other two
are **out of scope**.

CustomerFirst facts that shaped the design:

- Middleware API: `https://apps-zz-cusfst-mw-p-eus01.azurewebsites.net/api/{Service}/V1/{Method}`
  — RPC-style, 87 services / 359 routes mapped from the JS bundle.
- Auth: Azure AD B2C **custom policy** `B2C_1A_signup_signin`, tenant `pfgcustomerfirst`,
  SPA client_id `c68e7fae-80a1-42db-bd89-3fb37d1224a2`, MSAL.js 2.39 with
  `openid profile offline_access` — so a **refresh token exists** and the API client can
  refresh without a browser.
- Login is **email + password only** (confirmed on the live login page 2026-09-08:
  `#signInName`, `#password`, `#next` inside `#localAccountForm`). No 2FA →
  `auth_type: 'password'` → auto-relogin works, unlike USF/PPO.
- Quirk: the middleware answers **HTTP 203** (not 401) when unauthenticated. Spec-guarded
  in `performance_api_spec.rb`.

## Phase plan

1. **Supplier record** — DONE. `seed_suppliers.rb` entry, code `performance`.
2. **Authentication** — code written, awaiting live validation.
   `Scrapers::PerformanceScraper#login` drives the B2C form with Ferrum, waits for the
   redirect back to the SPA, then persists cookies + localStorage + sessionStorage
   (MSAL cache) to `session_data` — same shape as US Foods.
   `Scrapers::PerformanceApi#restore_session` digs the API-scope access token +
   refresh token out of the MSAL cache; refreshes directly against the B2C token
   endpoint (public client grant).
3. **API client / route recon** — `PerformanceScraper#log_api_traffic` logs every
   middleware call the SPA makes during login, so the first real validation run gives
   us live request shapes. Catalog candidates: `CustomerProduct`, `CustomerProductPrice`,
   `GetSearchResults`, `TypeAhead`.
4. **Catalog import** — wire into `staggered_supplier_import`.
5. **Lists** — `sync_all_lists`; remote_id must be per-account (WCW/PPO lesson).
6. **Matching** — existing matcher services; no new code expected.
7. **Ordering** — LAST, behind `checkout_enabled` + dry-run gates, with a full
   ordering-impact review. Candidates: `Order/V1/GetOrderCart`, `CreateOrderEntryHeader`,
   `SubmitOrderEntryHeader`. Nothing ordering-related is wired yet.

Until phases 4–5 land, `scrape_catalog`/`scrape_lists`/`scrape_prices` return `[]`
without opening a browser, so the post-validation import jobs no-op instead of flipping
a freshly validated credential to failed (spec-guarded).

## What did NOT work / dead ends

- No public PFG developer portal exists (unlike GFS's Apigee) — direct partner API access
  would need a business conversation, so we scrape/replay like the other suppliers.

## Open items

- [x] Live validation of the B2C login flow with real credentials — DONE 2026-09-08
- [x] Confirm the API-scope token appears in the cache — DONE (`scp: customer-first-site-api`)
- [x] Identify the customer-context call — `Site/V1/GetCurrentUserSite`; CustomerId GUID
- [x] Product images — `ProductImageUrlThumbnail` (blob SAS URL, expires 2070)
- [x] Phase 3 catalog — DONE (SearchProductCatalog + price merge, catch-weight fixed)
- [ ] Session TTL: measure how long the B2C refresh token lives (PPO's Cognito cap was 30d)
- [x] Phase 5 lists — DONE & live-verified 2026-09-08 (11-item "alfios" guide)
- [ ] Piece/each pricing: most products have a single CS UOM; handle multi-UOM
      (CS + EA/LB) → piece_price/piece_pack_size when encountered
- [ ] Deep import: SearchProductCatalog caps at 100 pages/term (~2500 items);
      term-based shallow import only. Assess coverage vs a category crawl later.
