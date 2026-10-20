# Fix: piece-sold prices multiplied by 12 on every missed guide price

**Date:** 2026-10-20 · **Status:** built and tested (full suite 2081/0), on branch `fix-compounding-piece-prices`, not committed or pushed · **Order placement:** the submit and cart code is unchanged. The fix changes the catalog price that screens, catalog search and the cheapest-supplier choice read. Read "Ordering impact" below.

## What happened

A read-only production check on Oct 20 found Chef's Warehouse **DM132 "Ultra Pasteurized Half & Half"** (pack `12x1 QT Piece`, $2.63 a piece) with a catalog price (`SupplierProduct` 4447) of **$54,535.68**. That's exactly $2.63 × 12⁴. The previous price was $4,544.64, which is $2.63 × 12³.

- **The bad price is on the shared catalog row, so it isn't a BIG ICE problem.** BIG ICE HQ (the sales test account, on Alfio's logins) only showed it first.
- **Guides synced that morning were reset to $2.63:** Alfio's Buon Cibo, alfios and BIG ICE. Their previous price was $54,535.68.
- **Rows that sync doesn't reach still showed $54,535.68,** because the catalog import copies the catalog price onto them:
  - BIG ICE's "Previously Purchased" list
  - D'oro's two Chef's Warehouse lists, stuck "syncing" since Oct 17
  - two old lists that had failed
- **Blast radius:** of 4,922 guide lines synced that morning, this was the only catalog row priced 5× or more above what its guide says a case costs. No order line in 60 days used it.

## Why: a loop in `ImportSupplierListsService#refresh_linked_product`

1. Chef's Warehouse prices piece-sold items per piece. The guide row stores $2.63, and the sync turns that into a case price for the catalog row: `estimated_total_price` returns $2.63 × 12 = $31.56. This part is intended.
2. **When a guide sync gets no price for the item** (37 Chef's Warehouse lines and 85 US Foods lines did on Oct 20), the row's `price` is nil. `effective_price` then borrows the catalog row's own price ($31.56, already a case price), and `estimated_total_price` multiplies it by 12 again, giving $378.72.
3. `extreme_price_change?` allows a jump that matches the pack size (built to let a per-unit price become a case price), so each ×12 got through.
4. **Nothing could bring it back down.** The guide's real $31.56 is a drop of 1/1,728, which the guard calls extreme, so it was refused every morning.
5. Every Wednesday the Chef's Warehouse re-price job resets the row with no guard, to the piece price. That's why the price was "only" 12⁴ and not higher: the cycle restarts weekly.

`ImportEmailPriceListService#refresh_linked_product` copies the same pattern, with no guard at all.

## The fix

- **Only a price the source sent can update the catalog price**, in both `ImportSupplierListsService#refresh_linked_product` and `ImportEmailPriceListService#refresh_linked_product`. A row with no price of its own still *shows* the catalog price (`effective_price` is unchanged) and still updates stock, pack and last-seen. It just can't feed the catalog's own price back in, multiplied.
- **The guard allows a drop by the pack size squared or more** (`compounded_pack_multiple?`: 12², 12³ … 12⁶, within 2%). That's the guide undoing compounded conversions. A drop of just the pack size (12×) is still blocked, as before.

**Healing:** after the push, the first guide sync that carries DM132's real price brings the catalog row from $54,535.68 to $31.56. The rows that sync doesn't reach pick that up from the next catalog import that touches DM132, or when their own list syncs again.

## Ordering impact

- **Unchanged:** cart, submit, and the checkout price check (`PriceVerificationService` reads the account's live price, so a supplier never charged $54,535.68).
- **What this price could have reached:**
  - **Catalog search and screens:** a chef adding DM132 from catalog search would have seen $54,535.68.
  - **Cheapest-supplier choice:** `SplitOrderService` takes `current_price`. An inflated item is never picked over another supplier, but if Chef's Warehouse were the only supplier for it, its order line would start at the inflated price until the price check.
  - **Savings figures:** protected. `SavingsCalculator` refuses an implausible spread (`implausible_spread`).

## What did NOT work / was rejected

- **Letting the guard allow any drop by the pack size (12×):** rejected. That's the "case price read as per-unit" glitch the guard exists to stop. Only the pack size squared or more is allowed.
- **Fixing DM132 by hand in production:** not done. It heals on its own on the first guide sync after the push, and production data writes go through code, not hand edits.

## Open items

- **The two writers disagree about what `current_price` means for piece-sold Chef's Warehouse items.** The weekly re-price writes the piece price ($2.63, by design in `cw-catalog-pricing.md`), and the guide sync writes the case price ($31.56). So the row flips each week. Between Wednesday 3:30 AM and the 8 AM sync, catalog search, catalog-side comparisons and the cheapest-supplier choice see a case at a twelfth of its price. This is Carmin's call (which meaning wins); it isn't changed here.
- **Guide lines that come back with no price** (37 Chef's Warehouse, 85 US Foods on Oct 20): why the supplier sent none is unexplored. With this fix they're harmless to the catalog price.
- **D'oro's Chef's Warehouse lists have been stuck "syncing" since Oct 17.** That's a separate problem, not investigated.
- **Until this ships,** the cycle restarts after each Wednesday re-price (the next is Oct 21, 3:30 AM).

## Tests

`spec/services/import_supplier_lists_compounding_spec.rb`:
- Three syncs with no price leave the catalog row at $31.56. The old code gave $54,535.68; this was verified by running the spec against the old code.
- A row with no price still shows the catalog price.
- A piece price still becomes the case price.
- An inflated row heals from the guide's real price.
- The guard allows 12² and 12³ drops, and still blocks a 12× drop and a drop that isn't a power of the pack size.
- The email import leaves the price alone when the price list sent none.
