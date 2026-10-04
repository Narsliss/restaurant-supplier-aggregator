# Chef's Warehouse catalog pricing

**Date:** 2026-10-03 · **Status:** built, full suite green (1,747 examples), not yet deployed or run · **Order placement:** NOT touched. This writes catalog prices only.

## Problem

Since the CW API rewrite (`1623eff`, Mar 23), the CW catalog import stores no price:

```ruby
current_price: nil, # Prices fetched separately if needed   (chefs_warehouse_scraper.rb format_catalog_product)
```

The "separately" step was never built, and catalog search hides unpriced items (`catalog_searches_controller.rb:21`, `aggregated_lists_controller.rb:502, 780`). So **13,444 of 15,624** live CW products (86%) were invisible to chefs. The 2,180 with a price got it from someone's CW order-guide sync. Alfio's complete CW guide hid this; a new restaurant with an empty guide would find almost nothing at CW.

## Live facts (read-only, Oct 3, Skyllar's CW login)

- **Speed:** `/web-api/product/prices` took **0.87 s per call**. A call of 20 variants covers 10 SKUs under both business units. A sample of 200 unpriced SKUs priced **199**.
- **Piece prices:** a **CS request already returns the piece price** as `secondaryUnitPrice`. A PC request returns identical data (e.g. 1118295: CS $34.36 / PC $18.90). "Piece" packs return PC as primary (QG9791 $11.74).
- **Stale prices exist:** DM132 is stored at $2.49; CW now charges $2.62.

## Fix

- **`ChefsWarehouseScraper#catalog_prices(skus, pack_sizes:)`:** one call per batch. Each SKU is looked up under BU 800001 and 133002, using the first unrestricted price above 0.
  - Same rules as order-guide pricing (`#fetch_order_guide_prices`): "Piece" pack sizes use the piece price, and `piece_price` / `piece_pack_size: 'PC'` are kept only when they really differ.
- **`ChefsWarehouseCatalogPricingJob`** is **manual only**: no schedule until Carmin has checked a run.

  | Option | Effect |
  |---|---|
  | `scope:` | `'unpriced'` (default) or `'all'` |
  | `limit:` | Price only the first N items |
  | `dry_run:` | Price but don't save |
  | `credential_id:` | Login to price with. Default: the catalog import's pick, the most recently used active login with a live session |

  - **Writes:** price, previous price, piece price, timestamps. Never stock flags, carts or orders. A failed batch is counted and skipped.
  - **Returns and logs a summary:** checked, saved, not priced, per business unit, with piece price, batch errors, still-unpriced count, plus 12 samples with a CW product link to spot-check.

## Run plan (each production run is a data write, approved separately)

1. `ChefsWarehouseCatalogPricingJob.perform_now(limit: 200)`, then spot-check the samples against chefswarehouse.com.
2. The full backfill: about 1,345 calls, **~20 minutes**.
3. Only then add it to the nightly CW import.

## Caveat

CW prices are account-specific. Catalog prices come from whichever login runs the job, the same as every other supplier's catalog today. The review-page price check re-prices against the ordering restaurant's own login before submit.
