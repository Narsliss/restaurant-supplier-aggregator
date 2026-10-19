# Live stock at the price check, every supplier (plan 3.3)

**Date:** 2026-10-19 · **Branch:** `claude/charming-grothendieck-c1c08e` · **Status:** built and tested, NOT committed, NOT pushed · **Plan:** `docs/plan-out-of-stock-all-suppliers.md` 3.3

**Carmin's decision (Oct 19): BLOCK** for Chef's Warehouse, What Chefs Want, Performance, Sysco and Premiere Produce. An item the price check reads as out right now keeps Place off until it's removed, on desktop and the phone. The phone blocks only on today's readings. US Foods still warns (D1).

## What Carmin asked for

Anything that sells out between the morning run and order time is caught at the price check, and the chef is told to take it out before placing the order (Oct 19). US Foods has done this since Phase 1. This extends it to the other five.

## What this change does

At the price check, each supplier now returns a definite answer for every item in the order (in / out), or "unknown" when it can't tell. The price check saves it on the item for everyone (stock is warehouse-wide) and records the reading (`stock_source: price_check`, `stock_checked_at`), even when nothing changed. Before this, all five returned a placeholder "in stock" that the price check ignored.

| Supplier | Live read at the price check | Out when | Unknown when | Extra calls |
|---|---|---|---|---|
| Chef's Warehouse | the restaurant's order guides, incl. "Recently Purchased" (CW has no stock lookup by item number) | count is 0 | item on no guide, or the guide read fails | 1 + one per guide |
| What Chefs Want | `unavailable` (already in its price read) | true | field absent | 0 |
| Performance | `IsOutOfStock` (already in its price read) | true | field absent | 0 |
| Sysco | the catalog search seller discovery already uses, 20 item numbers per call (the Prices query carries no stock) | `O`, phased out, or not orderable; D, R and N stay in | the search doesn't return the item, or fails | 1 per 20 items |
| Premiere Produce | `availability_status` (already in its price list) | `OUT_OF_STOCK` | no entry | 0 |

Items added after the price check (`VerifyItemPriceJob`) get the same reading.

A failed stock read never fails the price check: stock reads as unknown and the prices still stand.

## A bug found and fixed on the way

`SupplierProduct#update_price!` wrote whatever `in_stock` it was given. Since Phase 1 (US Foods) and Phase 3 (CW, WCW, Performance catalogs), scrapers return nil for "can't tell". Three callers pass the scraper's value straight in: `VerifyItemPriceJob`, `ScrapeSupplierJob` and `QuickPriceUpdateService`. nil reads as out of stock (`out_of_stock?` is `!in_stock`), so an "unknown" would have marked items out. **Fix:** nil keeps the current flag. Neither phase has been pushed, so this never reached production.

## What the chef sees

- **Desktop review:** unchanged rule. A non-US Foods "out" turns Submit off with "N items out of stock: … Remove them to submit this order." It now fires on what the supplier says right now, and the price check clears old "out" flags the supplier contradicts.
- **Phone review (new):** an item the supplier said is out **today** (at the price check or in the morning run) gets a red row: "Out of stock at Chef's Warehouse right now, so they won't take it. Tap − until it's gone to place this order." Place stays off, with "Remove the items marked out of stock to place." under it. Tapping − at quantity 1 removes the line and Place comes back. An old flag with no reading today shows nothing on the phone, as before, so stale data can't lock a chef out.
- **Checked in the browser at phone width** on a private copy of the dev database (dark mode): the red row, the note, Place off, and Place clearing after the item is removed. The copy was dropped afterwards; the shared dev database was not touched.

## Ordering impact

- **No cart, add-to-cart or submit code changed.** The block is on the review screens only, the same as desktop's existing block. If a blocked item somehow reached checkout, the supplier's refusal still stops the whole order and names the item (Step 0 to Phase 2).
- **The price check now writes stock for the five suppliers.**

## Specs

- `spec/services/scrapers/price_check_live_stock_spec.rb`: each supplier's live read (out / in / unknown, a failed read).
- `spec/models/supplier_product_spec.rb`: `update_price!` keeps the flag on nil; `record_live_stock!`.
- `spec/services/orders/price_verification_service_spec.rb`: the reading is recorded even when nothing changed.
- `spec/requests/review_stock_warning_spec.rb`: the phone blocks on today's reading, says how to fix it, clears once the item is in stock; an old flag stays quiet.

All 15 new specs fail on the Phase 3 commit (`c8d6dbb`).

## Open items

- CW's price check prices only business unit 800001; off-guide items in 133002 come back unpriced ("unverified"). Not changed here.
- Phase 5 adds a one-tap Remove on any line; today the phone removes by tapping − down to zero.
