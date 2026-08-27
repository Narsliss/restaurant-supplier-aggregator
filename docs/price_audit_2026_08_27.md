# Price audit — UnitParser pack-size gaps (2026-08-27)

Branch: `unit-parser-pack-size-gaps`

## What changed

1. **`UnitParser::WEIGHT_TO_OZ` gains `"z" => 1.0`** — Sysco abbreviates ounce as a
   bare trailing `Z` (`6x17.5Z`). `unit_pattern` matches longest-first, so a real
   `oz` is always consumed before this single-letter fallback.
2. **`UnitParser.parse_cw_can_pack`** — Chef's Warehouse encodes #10 cans as
   `6xLB10 CAN BC`. The trailing `CAN` token is required, and sizes outside
   `CAN_SIZE_TO_OZ` fall through rather than being guessed.
3. **`SyscoScraper#build_pack_size` re-attaches `uom`** when `size` carries no unit
   of its own. The GraphQL query already requests `packSize { pack size uom }`;
   `uom` was being discarded, producing unit-less strings like `12x11.5`.

## Ordering impact: none

`estimated_total` is the source of an order line's `unit_price`
(`aggregated_list_order_service.rb:135`), so newly-parseable packs could in principle
move submitted prices. Measured on production:

| Model | Affected rows | `price_unit` = `(none)` or `CS` (inert) | Convertible `price_unit` |
|---|---|---|---|
| SupplierListItem | 29 | 29 | **0** |
| SupplierProduct | 281 | 275 | 6 (`LB`) |

`estimated_total` returns the price unchanged when the price unit has no
weight/volume/count factor, which covers `CS` and blank. **Of the 25 affected SLIs
matched into a real list, zero have a convertible `price_unit`** — so no order line
price changes. The 6 SupplierProduct rows are display-only: the order path reads
`supplier_product.current_price` raw, never its `estimated_total_price`.

## Display impact

29 SupplierListItems (28 matched into lists) and 281 SupplierProducts go from
"no per-unit price, sits out every comparison" to competing normally.

## Sanity check on the new per-unit values

| Product | Pack | Case price | New basis |
|---|---|---|---|
| Whole Peeled Italian Plum Tomato | `6xLB10 CAN Case` | $43.27 | $1.10/lb |
| Tomato Ketchup 33% | `6xLB10 CAN Case` | $42.77 | $1.09/lb |
| Fire Roasted Red Peppers | `6xLB10 CAN BC` | $66.10 | $1.68/lb |
| COLUMELA Olive Oil Extra Virgin | `6x17.5Z` | $112.79 | $17.19/lb |
| PALACIOS Chorizo Iberico | `14x7.05Z` | $179.45 | $29.09/lb |
| BUCKHEAD PRIDE (ranged pack) | `10x15-17Z` | $11.79 | $1.18/lb |

All plausible for foodservice. The `Z` reading is corroborated by the data itself:
`VILAJUIGA WATER SPARKLING 11.83O` ships as `15x11.83Z` — the product name spells
out the unit the pack string abbreviates.

## Not done, deliberately

- **`70-90 CS`** (4 rows) — would need `cs` as a count unit, which collides with the
  very common "case" suffix (`3/10CT CS`, `5 LB CS`). Regression risk outweighs 4 rows.
- **`50 RL`, `4/250 EA` (gloves, register tape, lids)** — non-food. Weight is the wrong
  comparison basis entirely; these need a per-each/per-roll basis, not a parser fix.
- **Count-case produce formats** (`80/88 CT`, `CASE - 120/135 CT`, `8X10CT`) — these
  **already parse** correctly to `each`. They show as incomparable only because
  `ProductMatch.compare_by_unit` (the list-page engine) never consults
  `comparison_per_oz`. That is engine consolidation, not parsing.

## Verification

`bundle exec rspec` — 1056 examples, 0 failures.
