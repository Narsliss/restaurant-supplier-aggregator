# Sysco catalog import keeps the per-pound label

**Date:** 2026-09-27 · **Status:** fixed in branch, not deployed · **Audit:** `docs/price_audit_2026_09_27.md`

## Symptom

Alfio's matched list (org 7) showed Sysco "PACKER CHEESE LOAF PROVOLONE" (8413064,
`1x12 LB`) at $5.53 = $0.03/oz, marked **BEST**, on the ROSELI mozz/provolone row
against peers at $44–$72.

## Cause

Not detection. The live Sysco Prices API returns this SKU with
`case.netPrice 5.534`, `productInfo.isCatchWeight: true`, `averageWeightPerCase: 12.5`,
and `SyscoScraper#price_unit_for` correctly labels it `LB`.

The label was lost on the way into the database. `ImportSupplierProductsService` has two
write paths:

- **Catalog import** (term search): `build_update_row` / `bulk_upsert_existing` /
  `import_new_item` never wrote `price_unit` at all.
- **ID refresh** (`apply_refresh_updates`) does write it, but only covers SKUs the term
  search did *not* find.

So a catch-weight SKU the search finds keeps whatever unit it was first stamped with
(here `CS`, from the pre-853393b parser). The Sep 6 assumption that the nightly refresh
would heal all catch-weight rows was only true for SKUs outside the search results.

The list row itself (SLI 12558) is a catalog-search row; `SupplierListItem#stated_price_unit`
already falls back to the product's unit for those rows, so it inherits the fix without
being modified.

## Change

`app/services/import_supplier_products_service.rb`:

- `CATALOG_PRICE_UNIT_SUPPLIER_CODES = %w[sysco]` — suppliers whose catalog unit we store.
- `catalog_price_unit(item, current_unit)` — only ever moves a product **to** `LB`, and only
  when the same scrape brought the price. It never writes `CS`/`EA`: ~18.8k Sysco products
  have no stored unit and rely on pack inference (`#AVG` reads per-pound), and a stated `CS`
  would bypass that. Blast radius is therefore exactly the 428 audited products; a product
  that stops being catch-weight keeps `LB` on this path (unchanged from before — the ID
  refresh still relabels non-searched SKUs).
- Used in `build_update_row`, `import_new_item`; `price_unit` added to the upsert's
  `update_only`.

No backfill: the next daily catalog import relabels the 428 affected products.

## Ordering impact

None to submission code. `SupplierProduct#price_unit` is read by display, comparison /
BEST, savings, and as a fallback in order price verification — the same way the ID
refresh already sets it for 983 Sysco SKUs (the behaviour 853393b intended).

## What did not work / was ruled out

- First draft stored any unit the scrape stated (CS/EA too). Its audit only covered
  the →LB flips; the nil→CS side (~18.8k products) was unaudited, so it was narrowed to LB-only.

- "Detection misses this SKU" (the initial hypothesis) — disproved by the live payload.
- Heuristics on pack text ("pack mentions LB") — 4,750 candidates, only 428 actually
  catch-weight; would mislabel thousands of fixed-weight cases.

## Tests

`spec/services/import_supplier_products_service_spec.rb` — "#import_batch — the unit a
catalog price is quoted in": existing CS → LB, catalog-search row compares at $5.53/16 oz,
priceless scrape keeps the label, never writes CS/EA (blank stays blank, LB stays LB), new SKU labelled LB, non-Sysco supplier untouched.
The first three fail without the fix.

## Open items

1. Other suppliers' catalog scrapers (US Foods, WCW, PPO) also emit `price_unit` that the
   catalog path discards. Enabling them needs its own audit.
2. `8845582` duck bratwurst: `isCatchWeight: true` but price looks like a case total.
3. Org 8 guide-row pork belly (`5238930`, `4x3 LB`, $7.80) — unit from the row/inference,
   not changed here.
