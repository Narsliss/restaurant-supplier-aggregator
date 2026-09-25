# Noche (list 12): additive supplier augmentation, 2026-09-25

**What:** we added more suppliers to the items still on Noche's matched list, using the blueprint plus a checked catalog search. This is the same method used for alfios list 8. Carmin authorized it and ran the apply on production on Sep 25 at 15:18.

## Why

Noche's list was created on May 27, and 395 of its 491 rows were formed before the blueprint (Product spine) was applied on Jul 24. Rows formed that way never got blueprint links. On top of that, the chef removed 284 rows with "Remove from list", and those removals are intentional curation that we left alone. That left 190 visible rows, and 88 of them had only one supplier.

## Method

1. For every visible row and every connected supplier the row lacked, we took candidates from:
   - blueprint (spine) links, and
   - an IDF name-similarity search of that supplier's catalog, with a 0.32 threshold, up to 2 candidates per slot, and a price-per-unit sanity gate.

   The script is `tmp/noche_assess/block_noche.py`.
2. We checked all 357 candidate pairs by hand-review agents, not by keyword rules.
   - Result: 210 match, 133 no_match, 14 uncertain.
3. We built the plan with `tmp/noche_assess/build_plan.py`:
   - Take only high or medium "match" verdicts, and drop medium ones whose reasoning hedges.
   - Add at most one product per (row, missing supplier).
   - Use each product in at most one row.
   - Never add a product that is already anywhere on the list, including removed rows. This dropped 25.
   - Skip unpriced products. This dropped 17, per Carmin: 9 Chef's Warehouse, 7 US Foods, 1 PPO.
4. We applied with `tmp/noche_assess/apply_template.rb`, dry run first. The script re-checks every guard at run time and never changes a row's status. Confirmed rows stay confirmed, per Carmin, so the chef is not flooded with review work.

## Result (verified on production)

- There were 109 additions across 85 rows: 105 on confirmed rows and 4 on auto_matched rows. There were zero skips, and zero of the added items are unpriced.
- Matched items on list 12 went from 763 to 872. Row status counts are unchanged: 197 confirmed, 9 auto_matched, 1 unmatched, 284 rejected.
- Suppliers per visible row:

  | Suppliers per row | Before | After |
  |---|---|---|
  | 1 | 88 | 62 |
  | 2 | 65 | 41 |
  | 3 | 29 | 46 |
  | 4 | 8 | 41 |

- Rollback records are in `tmp/noche_assess/rollback.json` (gitignored). Each record is {row, pmi, sli, sli_created, status}, and all 109 supplier_list_items were newly created. To roll back, delete those product_match_items and supplier_list_items, then refresh the supplier-list product counts.

## What did not work or was not done

- Blueprint links alone would have reached only 28 rows, because only 181 of the 337 visible items are on the spine. The sample also found a few bad blueprint links, where IQF blueberries and strawberries are linked to fresh ones (4 of 26 sampled spine pairs were wrong). Those links are still in the blueprint.
- We did not add Performance, because Noche has no Performance credential.

## Open items and side effects

- In the order builder, rows where a newly added connected supplier is cheaper will now default to that supplier and show BEST.
- Missed-savings reports may rise for rows that gained a cheaper peer.
- Unpriced catalog products: most Chef's Warehouse catalog products have never had a price, and US Foods writes $0.00 for "no contract price". This includes 145 items on real US Foods order guides. It is tracked as a separate investigation.
