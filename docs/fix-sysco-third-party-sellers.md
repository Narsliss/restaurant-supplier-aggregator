# Fix: Sysco third-party items priced and ordered under the wrong seller

**Date:** 2026-09-27 · **Status:** built, full suite green (1,583 examples), not yet deployed · **Order placement:** TOUCHED — Sysco `add_to_cart` / submit line sellers, price checks

## What happened

The second live Sysco order (#337, Alfio's, 4 items) failed at the cart step with Sysco's `PPS-007 "One or more product details could not be retrieved"` (503). Nothing was submitted. Order #336's earlier failure was different; it's covered in [fix-sysco-cart-line-fields.md](fix-sysco-cart-line-fields.md).

Two of the four items are sold on Sysco's site by **other sellers**: Dole pineapple is seller `2011` and Melting Forest yuzu is `3473`. Sysco's own stock and our account are `USBL`. Every Sysco call named `USBL` for every item. Under the wrong seller the Prices API returns the product with **no price**, and `updateOrderV2` rejects the whole cart.

## Why the matching list still showed prices

The catalog import prices search results with each result's own `sellerId` (`graphql_get_prices`: `r['sellerId'] || tokens[:seller_id]`), so first-import prices were right. The seller was then **discarded**; there was nowhere to store it. Everything afterwards used `USBL`:

- the nightly price refresh (`refresh_batch`)
- the order price check (`scrape_prices`)
- order-guide pricing (`graphql_get_list_items`)
- cart and submit

Under `USBL` the refresh got the product back with no price, counted it "seen", and kept the old price. So third-party prices froze at their first import (yuzu showed $24.00 against a live $28.80), and delisted items kept a live-looking price forever (Boardwalk 6070898, $43.12).

## Live evidence (Sep 27, read-only unless noted)

- **Same SKU, two sellers:** under `USBL`, pineapple, yuzu and Boardwalk had no price. Under their own sellers, pineapple was $33.22 and yuzu $28.80. Boardwalk can't be found by search at all.
- **Draft-only probe** (created, filled, deleted, never submitted): pineapple (2011), yuzu (3473) and sugar (USBL) went on **one draft together**. Sysco stored each line with its seller and correct price, total $102.61, delivery Oct 7. Mixed-seller orders are accepted at the cart step.
- **Audit of the 682 Sysco products on chefs' lists:**

  | Group | Count |
  |---|---|
  | Priced under `USBL` | 551 |
  | Third-party (another seller) | 110 |
  | – stored price ≠ live | 28 (e.g. Karat nitrile gloves $53.70 vs live $44.75 on 4 SKUs; pomegranate juice $78.43 vs $72.85) |
  | – no stored price at all | ~10 |
  | Not found by search (likely delisted) | 11 (Boardwalk paper and liners, Dixie parchment, 16/20 shrimp, Caputo ciliegine…) |
  | `USBL`, but Sysco gives no price | 10 (spices and produce). Unchanged by this fix |

  Third-party items aren't only the `60xxxxx` SKUs; Monin lime syrup 5899810 is seller `SOTF`. The fix goes by seller, not SKU pattern.

## The fix

- **`supplier_products.supplier_seller_id`** (new, nullable string).
- **The seller is learned from the catalog import:** `parse_search_result` carries `seller_id`, and the import service stores it on new and existing rows, keeping a known one when a scrape has none. That's a three-line change to the shared import service.
- **`SyscoScraper#price_with_sellers(skus)`** is used by the refresh, the price check, order-guide pricing and the cart:
  1. Price each SKU under its stored seller, or `USBL` when none is stored.
  2. A SKU with no stored seller and no price under `USBL` is looked up **once** by catalog search. The seller found is saved, even when it's `USBL`, so it's never searched again, and the SKU is re-priced under it.
  3. If search can't find it either, it's **unlisted**.

  Lookups are batched: 20 SKUs per search call, the same trick as `fetch_pack_sizes` in 76e02fd. A SKU the batch doesn't return is re-checked alone before it's called unlisted, and a failed search marks nothing. At most `SELLER_DISCOVERY_LIMIT` (5,000) SKUs are looked up per scraper instance. The first nightly refresh meets roughly 16K rows with no stored seller, so the backlog takes a few nights at about 250 calls a night. Order-time checks look their SKUs up at once.
- **Refresh:** unlisted SKUs count as **missed**, not seen. The existing miss tracking then discontinues them after 3 misses (`DISCONTINUE_AFTER_MISSES`).
- **Cart (`add_to_cart`):**
  - Sellers are resolved *before* creating the draft.
  - Unlisted items are left off and returned in `failed` ("No longer sold on Sysco"). `OrderPlacementService#handle_skipped_cart_items` auto-removes them with a note and re-checks the minimum.
  - If every item is unlisted, no draft is created.
  - Each line carries its own `sellerId`, and `updateOrderV2` now returns `sellerId`/`siteId` per line.
- **Submit / remove:** each line keeps the seller it was added under, falling back to the account seller for older caches.

## What did NOT work / was ruled out

- My first theory for #336 (a wrong seller on the Boardwalk item) was wrong for #336, which failed on missing fields. It was right for #337's third-party items.
- A missing `price_unit` doesn't mark third-party items: ~16.5K Sysco rows have none by design (see `catalog_price_unit`).
- `price_updated_at` records when a price last **changed**, not when it was checked, so it can't measure staleness.

## Open items

- **Submitting a mixed-seller order is unverified.** The cart accepts it (probe). Whether `submitOrderV2` accepts it, or splits it into several Sysco orders, only shows on a real order. Check Sysco's portal after the first one.
- **Delivery days for third-party sellers:** `getDeliveryDays` is account-wide, and the draft kept Oct 7 for all sellers. Whether drop-ship sellers deliver on the Sysco route is unknown.
- **Unlisted items keep their stored price until discontinued (3 nights).** They can't be ordered, because the cart leaves them off with a note, but the builder still shows them until then.
- **Seller backlog:** list items get their seller the first time they're priced (refresh, guide sync or order), and the rest of the catalog over the next few nights.
- **Shared test DB:** the other worktrees' spec runs reload their own `schema.rb`, which drops `supplier_seller_id` from the test DB until they rebase. Re-run `RAILS_ENV=test bin/rails db:migrate` if specs say a migration is pending.

## Follow-up (same day): delivery date read day-first

With the seller fix live, the retry of #337 built a mixed-seller cart. It had all 4 items, 0 failed, $544.73, with pineapple → 2011 and yuzu → 3473. It was then refused **before submit** with "not accepting delivery on 2026-07-10". The chef chose Oct 7.

Sysco now returns the draft's `deliveryDate` as `"10/07/2026"`. It used to be epoch ms (and ISO at times). `checkout` read strings with `Date.parse`, which is day-first, so it got Jul 10, and the pre-submit availability check rejected it.

Fix: `SyscoScraper#sysco_delivery_date` reads slashed dates month-first (`%m/%d/%Y`), keeps ISO and epoch-ms, and returns nil if it can't read the value. Both the display string and the availability check use it. There are specs for all three formats and for a US-format draft date passing and failing the check.

Side effect seen: a failure inside `checkout` leaves the Sysco draft open (here `674c24ad…`). The next placement's `clear_cart` deletes open WEB drafts. Note that it would also delete a draft a chef built by hand on sysco.com. That behaviour predates this fix and isn't changed by it.
