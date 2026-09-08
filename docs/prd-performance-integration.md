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
- [ ] Phase 5 lists — endpoints identified, BLOCKED on a populated guide to verify:
      - `ProductListHeader/V1/GetProductListHeaders?customerId=` (GET) → guides.
        This account has ONE real order guide: **"alfios"**, ProductListHeaderId
        `225278a5-0996-49df-826a-1e90600b375e`, ProductListType 3 — but
        **ProductListDetailCount: 0** (brand-new supplier, guide not yet populated).
        A second list is a type-4 all-zeros-GUID system list.
      - Items via `ProductListCatalogSearch/V1/SearchProductListCatalog` (takes
        ProductListHeaderId) — returns the SAME CatalogProduct shape as phase 3,
        so `format_catalog_product` (incl. catch-weight) is reusable.
      - Cannot live-verify the list-items response until "alfios" has ≥1 item.
        Do NOT ship blind list parsing (cf. the WCW "synced zero items silently"
        regression). Verify once the guide is populated.
- [ ] Piece/each pricing: most products have a single CS UOM; handle multi-UOM
      (CS + EA/LB) → piece_price/piece_pack_size when encountered
- [ ] Deep import: SearchProductCatalog caps at 100 pages/term (~2500 items);
      term-based shallow import only. Assess coverage vs a category crawl later.
