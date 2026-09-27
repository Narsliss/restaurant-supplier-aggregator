# Price audit — Sysco unit-less pack heal (2026-09-27)

Branch: `claude/adoring-taussig-b9eebc`

## The report

Alfio's matched list (org 7) "Flour - Cake" row: Sysco `KINGAR FLOUR CAKE BLEND
UNBLEACHED` (SKU 6030537) showed pack `6x2`, $66.97, and no per-unit line, so it sat
out the comparison against Chef's WH ($0.04/oz) and WCW ($0.09/oz).

## Root cause

Not the parser: `UnitParser` reads `6x2 LB` fine ($0.3488/oz). The stored string had no unit.

- Sysco's live payload for 6030537 is `{pack: "6", size: "2", uom: "LB"}`, and
  `build_pack_size` has produced `6x2 LB` from it since 3e0705e (Aug 27).
- That fix only reaches products the **catalog term search** returns, because only
  that path rewrites `pack_size`. The long tail is kept alive by
  `refresh_known_skus`, whose `Prices` query (`getProducts`) has no `packSize`
  (probed on prod: `productInfo.packSize` comes back `nil`). Those products keep
  getting priced every night and never get their pack repaired.
- Prod, Sep 27: **12,849 of 35,522 Sysco products** (12,607 active) had a bare
  `NxN` pack. All were created before Aug 27, and none since. 118 Sysco list items
  carried the same stale string.

## What changed

1. **`SyscoScraper#fetch_pack_sizes`** is a read-only batched lookup. Catalog search
   matches item numbers, and 20 space-separated SKUs return together in one call
   (probed: `"6030537 6030552 6030532"` returns exactly those three; `OR` does not work).
   Only exact `productId` matches are kept.
2. **`ImportSupplierProductsService#heal_unitless_pack_sizes`** does three things:
   - It selects active products whose pack is exactly `N[.N]xN[.N]`.
   - It replaces a pack **only** when the fresh string is the old one plus a unit
     word (`6x2` → `6x2 LB`), and repairs linked list items holding the identical
     stale string with a matching (or blank) SKU.
   - **Built-in price gate:** it skips the row entirely if the new pack would change
     the product's `estimated_case_price` or any linked item's
     `estimated_total_price`. The order builder puts `estimated_total_price` into
     `data-supplier-price`, which becomes the cart price.
3. **Sysco grams:** `build_pack_size` maps Sysco `uom: "G"` to `GR`. Sysco's uom codes
   use `GAL` for gallons and `G` for grams, but `UnitParser` reads a bare `G` as
   gallons (deliberately, for other suppliers). `64x140 G` truffle honey parsed as
   1,146,880 fl oz, so it came out at $0.0004 per unit. With `GR` it's $1.58/oz.
   `UnitParser` is unchanged.

## Ordering impact: none (measured)

Read-only dry run on prod (same lookup, guards and gate, inline; nothing written):

| Set | Checked | Would heal | Not returned | Numbers changed (left alone) | Skipped by price gate |
|---|---|---|---|---|---|
| Products linked to a list item | 100 | 90 | 10 | 0 | 0 |
| Products with a non-case `price_unit` | 1 | 0 | 0 | 0 | **1** |
| Random sample of the rest | 1,000 | 812 | 167 | 21 | 0 |

- **91 list items would heal. `estimated_total_price` is identical before and
  after for all 91** (full table in the session output; 117 of 118 stale list items
  have a blank `price_unit`, 1 is `CS`). 70 gain a per-unit price, including
  Alfio's 19675 → $0.3488/oz.
- The gate's one catch: `LOCATELLI CHEESE PECORINO ROMANO` (7305886), `1x7.5` at
  $15.25 **per LB**. Its estimated case price would go from $15.25 to $114.38. That's
  arguably correct, but it's a price move, so the heal leaves the row alone.
- **Unit overrides:** 0 Sysco overrides have a unit-less fingerprint, so the heal
  raises no stale-weight alerts.
- **Grams remap:** 57 Sysco products are already stored as `… G` (all grams:
  `4x800 G` chocolate, `200x12 G` mayo) and 0 list items. Estimated totals that would
  move if they became `GR`: **0**. They're 18 `CS`, 39 blank.

Units the sample healed into: OZ 476, LB 144, FOZ 102, EA 38, CT 34, GAL 20, CS 19,
IN 17, G→GR 9, KG 7, plus a few BAG/ML/PIECE/ROLL.

**Interaction with f554259 (catalog import keeps Sysco's per-pound label), landed the
same day:** that change relabels ~428 catch-weight Sysco products to `LB` through the
catalog import. The measurements above predate it. That doesn't weaken the guarantee,
because the heal's gate runs at heal time, after that night's catalog import has
applied the relabel. Any product now labelled `LB` whose total would move with a
weighted pack gets skipped, the same way the Pecorino row is. See
`docs/price_audit_2026_09_27.md` for that change's own audit.

## Display impact (expected, and visible to chefs)

About 81% of the ~12.6K stale products gain a readable pack. Many join per-unit
comparisons for the first time, so **BEST pills, the order builder's pre-selected
supplier, and missed-savings lines can change on affected rows.** On Alfio's
Flour – Cake row Sysco becomes the cheapest at $0.022/oz, versus $0.04 and $0.09.

Values worth a second look, because they're odd but faithful to Sysco's own data:
- Non-food containers and lids compared by capacity (`2500x4 OZ` bowls, `50x16 FOZ` lids).
- `1000x100 EA` gloves: 100,000 each.

Both are display-only and subject to the existing missed-savings plausibility gates.

## What did NOT work / was rejected

- **Adding `packSize` to the `Prices` query**: the field resolves to `nil` on
  `getProducts`. Changing that shared query would also have touched `scrape_prices`.
- **GraphQL introspection** to find another field: disabled on Sysco's Apollo server.
- **Fixing it in `UnitParser`**, either by guessing a unit for `NxN` or remapping `G`
  globally: the unit changes the price 2.2x (LB vs KG), and `G` means gallons for
  other suppliers.

## Open items

- **Wiring:** `SyscoCombinedImportJob` calls `heal_unitless_pack_sizes` after
  `refresh_known_products` and before the list import, in its own `rescue`, and
  records the counts in the scraping log's `metadata.pack_heal`. After the first
  nightly run, check that log: `healed` should be around 10K and
  `skipped_price_move` in the single digits.
- Expected API load: about 640 searches the first night, then roughly 125/night
  retrying the ~17% of SKUs Sysco doesn't return for the import account.
- **Pack census, all suppliers (prod, Sep 27):** Sysco is the only systemic case
  (40.8% unreadable, 12,607 of them this `NxN` shape; most of the rest are equipment
  sized in inches). Every other supplier is ≤2.7%, mostly non-food (FT/RL/SL) or
  catch-weight packs with no unit stated. US Foods has the same price-only refresh
  but only 16 unreadable products. Re-run the census before chasing a new "no
  per-unit price" report, and fix by shape.
- The 57 `… G` products correct themselves only when the term search returns them.
  They aren't `NxN`, so the heal won't reach them.
- 21 in 1,000 sampled packs changed numbers upstream. The heal leaves them for the
  catalog import, which rewrites them only if the term search reaches them.
- The 17 two-number shapes (`6 .77`) are untouched.

## Verification

`bundle exec rspec` (full suite, via the PreToolUse hook) passes. New specs:
- `spec/jobs/sysco_combined_import_job_spec.rb`: the heal runs between refresh and
  list import, and a heal failure doesn't stop the order-guide import.
- `spec/services/scrapers/sysco_scraper_spec.rb`: `#fetch_pack_sizes` (the 6030537
  payload, fuzzy-match rejection, failure tolerance, batching) and the grams remap.
- `spec/services/import_supplier_products_service_spec.rb`:
  `#heal_unitless_pack_sizes` (heal plus list item, unit-less-only selection,
  changed numbers left alone, the price gate, a SKU-mismatched list item left alone,
  and a scraper without lookup support).
