# Fix: supplier-guide sync erased chef matches and catalog-search additions

**Date:** 2026-09-25 · **Area:** list sync (`ImportSupplierListsService`), which feeds matching and ordering · **Status:** built, full suite green (1,335 examples), not yet deployed

## What happened

Carmin was impersonating Nate Crawford and found confirmed rows on Noche's list (list 12) with every supplier cell reading "No match". They were empty: 19 rows on list 12 had zero items, and 14 of them were confirmed.

- **Sep 11, roughly 3:45 to 7:00 pm:** new rows were built in the matching modal from items on Nate's supplier lists, and each was confirmed about a minute later. Each row's `canonical_image_supplier_product_id` points at one of its own products. The `canonical_image_belongs_to_match` validation proves the row held that item when `confirm!` saved it.
- **Sep 15, 20:44 UTC (4:44 pm Eastern):** `ImportSupplierListsJob` ran with `force` and `refresh_seeded` for all of Nate's credentials. The worker log for deployment `93c9a6e4` shows these removals:

  | List | Items removed |
  |---|---|
  | CW "noche" | 7 |
  | CW "Hedley & Bennet Aprons" | 4 |
  | WCW "Order Guide" | 12 |
  | PPO "Recently Purchased" | 7 |
  | USF "Order Guide 862873" | 1 |

  Every sync completed with no errors, so the suppliers did return those guides without those items.
- `upsert_list` deleted every list item whose SKU was not in the latest scrape. `SupplierListItem has_many :product_match_items, dependent: :destroy`, so the chef's match went with it. Nothing records what was deleted.
- `MatchedListCleanupService#purge_empty` never removes chef-touched rows. The emptied confirmed rows therefore stayed, showing "No match" for every supplier.

## The larger problem found at the same time

The removal step ignored `source`, so it also deleted every item that **catalog search** had added. On production, no catalog-search item has ever survived a sync of its list; the only exception is Sysco list 99, which syncs differently. The following were all due to be wiped at the next sync:

- Today's 144 Performance additions on alfios list 8, which live on Performance list 173 and sync daily at 8 AM.
- Today's 109 Noche additions.
- Any off-list builder additions.

This likely explains much of the "sparse matching" seen on lists that had catalog search run over them.

The empty rows on lists 8, 10, 14, 6 and 11 (76 visible across all lists) are most likely the same mechanism acting over time. PPO "Recently Purchased" is especially exposed because it is a rolling window.

## The rule now

The supplier guide is where a matched list **starts**, not what it **is**. When an item drops off a guide:

- **If no matched row uses it:** it is removed, as before.
- **If a matched row uses it, whatever the row's status:** it is kept and re-marked `source: 'catalog_search'`.
  - It stays orderable. Placement never required the guide; WCW, for example, resolves SKUs that are not on the guide through catalog search (`what_chefs_want_scraper.rb:592`).
  - Its price stays current, because catalog imports propagate prices to linked list items (`import_supplier_products_service.rb:198`).
- **Items added by catalog search are never removed by a guide sync.**
- **If the supplier lists the item again,** it reverts to `source: 'order_guide'`.
- **If the supplier returns an empty guide,** nothing is removed. That guard is unchanged.

"Re-match All" (`AiProductMatcherService`) still clears catalog-search items on purpose. It is destructive by design and user-initiated.

## Tests

`spec/services/import_supplier_lists_service_spec.rb`, in the block "items that drop off the guide", covers:

- an unmatched dropped item is removed;
- a matched dropped item is kept, for both confirmed and auto_matched rows, and becomes catalog-backed;
- catalog-search items are never removed;
- an item that is back on the guide reverts to `order_guide`;
- an empty guide removes nothing.

## Open items

- **Restoring the rows that are already empty.**
  - For 12 of the 19 empty Noche rows, the product is known from `canonical_image_supplier_product_id`. Those rows could be re-attached from the catalog, but only with Carmin's approval, because it writes to a user's matched list.
  - The other 7 Noche rows, and older empty rows on other lists, cannot be reconstructed, because nothing recorded what they held.
- **The UI does not mark items that are no longer on the guide.** Carmin does not care whether an item remains on the supplier guide, so nothing is shown.
