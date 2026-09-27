# Fix: matching ran before a new supplier's guide finished importing (Sep 27 2026)

## Found by
Carmin's end-to-end test: delete and re-add CJ's alfios Performance connection. ("I am worried about things like race conditions with downloading order guides", then "and this is why we check it end to end".)

## What happened
- `ImportSupplierListsService#upsert_list` saves a new guide list **before** importing its items.
- Saving fired `SupplierList#auto_add_to_matched_list`, which attached the list to the restaurant's matched list **and started `SyncNewProductsJob`** straight away, on a different queue from the import.
- Live timeline (worker logs, Sep 27):
  - 18:22:01: list 176 attached, matching started.
  - Then the import logged "134 items imported".
- Matching took its snapshot of new items mid-import. It placed 4 Performance guide items (31 on the previous reconnect), and unmatched Performance guide items rose from 89 to 118. Nothing re-runs matching when the import finishes, so they stay stranded until someone presses "Sync New Products".
- This affected every new supplier connection, not just today's work.

## Fix
- `SupplierList#auto_add_to_matched_list` still attaches the list, but no longer starts matching.
- `ImportSupplierListsService#match_new_lists!` starts `SyncNewProductsJob` for the matched lists of the guide lists created in this import, **after** all their items are in. Routine re-syncs of existing guides don't trigger it.
- `ImportEmailPriceListService` does the same for a newly created email price list (it also relied on the creation trigger).
- The catalog-created lists (`catalog_searches_controller`, `Catalog::AddProductToMatchedListService`) link their item to a row directly and never needed matching.

## Tests
`spec/services/import_supplier_lists_match_timing_spec.rb` (4). On the previous code, matching started with **0 of 3** guide items imported. Full suite: 1,543.

## Also verified in the same test
The shared-map fill (`docs/product-map-fill.md`) ran live on alfios and added 112 links: Performance 40, WCW 29, PPO 17, US Foods 12, CW 9, Sysco 5.
