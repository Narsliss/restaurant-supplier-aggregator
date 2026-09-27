# Use the shared product map when a supplier is added (Sep 27 2026)

## Why
Carmin: "why are we not using the carefully created shared product map we spent weeks creating on new supplier adds?" and "the blueprint is freaking useless if it isn't doing that."

A connection was deleted and re-added (CJ's alfios Performance login, #127 to #137). Deleting a connection deliberately removes its supplier from the matched lists, so 158 Performance links came off alfios list 8. The reconnect's automatic matching put back only 46. Investigation showed:
- **The map was used in one direction only.** `IncrementalProductMatcherService` ("Pass 1: shared Product link") checks a new supplier's **order-guide items** against existing rows. Nothing asked the reverse, "for each row, what is this supplier's product on the map?", so the map's knowledge of the supplier's full catalog never reached rows.
- **The Sep 25 Performance fills were hand-run scripts** (`rake baseline:attach` for the map, `tmp/pfg_alfios_match` for rows). Only 37 of the 158 were map links; 121 were review-approved name matches that were never written into the map.
- Carmin: do **not** restore previous matches after a deliberate supplier delete. Only use the shared map on supplier adds.

## What changed
- `ProductMapFillService`: for each supplier with a list mapped to the matched list (connected at that restaurant), and each row, it adds the supplier's map product (`SupplierProduct#product_id` equal to one of the row's products). It reuses catalog search's item creation (`source: catalog_search`). Guards:
  - skip rejected rows;
  - skip rows that already have that supplier;
  - skip rows where a chef removed that supplier (`MatchItemRemoval` `chef_edit`);
  - use exactly one map product from the supplier (ambiguity is skipped);
  - the product must be priced and not discontinued;
  - the product must not already be anywhere on the list.
  - Only unmatched rows are promoted (to auto_matched); confirmed rows stay confirmed.
  - `dry_run:` is supported.
- `SyncNewProductsJob` runs the fill after guide matching, and also when there are no new guide items. This job runs when a supplier's list is first attached to a restaurant's matched list (a supplier added or reconnected) and from the builder's "sync new products" action. A failure in the fill is logged and never blocks guide matching.
- Removal records are not used, per Carmin.

## Tests
`spec/services/product_map_fill_service_spec.rb` (11). Full suite: 1,539.

## Open
- The map only knows what was written into it. The 121 review-approved Performance matches from Sep 25 are not on it, so they won't come back through this path.
- Nothing writes future confirmed matches into the map. That is a separate decision (chefs' deliberate stand-ins must not spread across restaurants).
