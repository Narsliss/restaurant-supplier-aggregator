# US Foods order placement checks (plan Phase 1: steps 1.1, 1.2, 1.4, 1.5, 1.6)

**Date:** 2026-10-19 · **Status:** built incl. 1.3 (D1: warn), full suite green (1,820), NOT committed or deployed · **Order placement:** TOUCHED (US Foods add-to-cart, clear, a new line check, checkout and submit; shared importer reinstatement). Every change adds a stop or makes a result honest. No gate removed. · Plan: `docs/plan-out-of-stock-all-suppliers.md`. Step 1.3 built per Carmin's D1 (warn at the price check).

## Why

US Foods could ship a chef a short order with nobody noticing (checkout audit A1-A5 in `fix-cw-out-of-stock-message.md`):
- `add_to_cart` always reported nothing failed.
- A failed cart write fell back to OUR local copy of the order, and checkout submitted that.
- Nothing compared US Foods' lines with ours.
- Any answer from submit counted as placed.
- Discontinued items went out priced at $0.
- A timeout at submit became a retryable "failed", which risked a double order.

US Foods placed 8 live orders in the 30 days to Oct 19.

## What changed

**1.1 Cart truth**
- **Updates (`us_foods_api.rb`):**
  - `add_items_to_order` returns US Foods' copy of OUR order or nil. No fallback to the local copy, and never `result.first`, which could be another, already-submitted order.
  - `normalize_order_response` returns nil instead of a different order.
- **Clear (`us_foods_scraper.rb`):** `clear_cart` fails closed when the clear doesn't take, lines remain, or the cart can't be read.
- **Line check:** new `verify_cart_matches!`.
  - Re-reads the open order (`GET /order-domain-api/v1/orders`) and compares every line by product number.
  - Missing, extra, a changed quantity, or cases turned into eaches each give a `CartMismatchError`, after the cart is emptied.
  - If the order can't be read back, it stops.
  - On success, checkout submits US Foods' own copy.
  - All-missing mismatches are named to the chef by Step 0's service change.
- **Stock gate:** first built with `confirms_lines_before_submit?` overridden to **false** (cached stock check kept). **Superseded by 1.3 (D1):** now true, so the cached flag no longer stops US Foods orders.

**1.2 Submit truth**
- **Open cart only.** Checkout refuses to submit anything but the open cart (`IN_PROGRESS`). A submitted order would otherwise go to `/updateSubmittedOrder` and be edited.
- **What counts as placed.** Placed = the submit answers with OUR orderId and a status past IN_PROGRESS.
  - The confirmation is `tandemOrderNumber` when present, otherwise US Foods' orderId.
  - **This is what every live US Foods order has carried.** All 22 in the last 120 days are confirmed with the orderId UUID. Order 482 (today) answered `status: SUBMITTING` with no tandem number, which US Foods assigns later when it re-files the order.
- **Anything else is read back** (no answer, a timeout, another order's answer, still IN_PROGRESS):
  - still in the cart → "not placed, safe to try again";
  - found submitted in recent orders → confirmed;
  - otherwise → `OrderUnconfirmedError` ("check US Foods before reordering"), `pending_manual`, which can't be retried.

**1.4 Piece lines:** a PC line stops the order before anything touches US Foods: "US Foods piece ordering isn't set up in EnPlace yet — order it by the case". No US Foods order has used PC in 180 days, and no USF product has a piece price, so nobody is affected today.

**1.5 Price errors at checkout:** a line priced with an error stops the order and names the item, before the dry-run return, so dev and prod match. The cart is emptied.
- 1102 "doesn't carry this item anymore"
- 1104 "has discontinued this item"
- 1106 "reserved for another US Foods customer"
- no price at all
- no prices whatsoever → "Couldn't get US Foods prices".

**1.6 Morning data**
- **Session renewal (`us_foods_api.rb#request`):** an expired token (known expiry only) is renewed before the call, and a 401 renews and retries once. A guard stops the renewal from renewing itself.
- **Reinstated items (`import_supplier_products_service.rb`, shared by all suppliers):** a product reinstated after being discontinued gets `in_stock` back, unless the scrape itself says out (catalog path). The refresh path now writes `in_stock` too.
- **Not done here:** reading the products v2 `inventory` block into the morning import. That needs Phase 3's stock fields and shadow mode.

**1.3 Live stock at the price check: Carmin's D1 (Oct 19). Warn, don't block. Block only discontinued.**
- **Read.** `UsFoodsScraper#scrape_prices` (the price check) reads the products call's `inventory` block. It is already fetched there, so there's no extra call.
  - Available = cases on hand − reserved − waitlisted (eaches for a PC line).
  - `true` / `false`; `nil` when there's no product, no inventory block, or the item isn't regular warehouse stock (`productType` ≠ "R").
  - It used to be `product.present?`, so a failed lookup read as "out".
- **Save.** `PriceVerificationService` saves live stock onto the shared product both ways, even when the price didn't change. That happens only for scrapers that declare `reports_live_stock?` (US Foods). Other scrapers return a placeholder `in_stock: true` that must never clear a real "out"; nil changes nothing.
- **Show** (`OrdersHelper#order_item_stock_state` → :ok / :warn / :block):
  - **Desktop review:** a US Foods out-of-stock item is amber, "Out of stock — may be shorted", with a banner saying the chef can remove it or place it ("you'll get an email if anything is shorted"). **Submit stays on.**
  - **Discontinued items, and every other supplier's out-of-stock items, still block Submit**, as before.
  - **Status poll:** each item carries `blocking: true/false`.
  - **Mobile review:** a new amber note on US Foods out-of-stock items: "Remove it with −, or place it and they'll send what they can — you'll get an email if it's shorted." Mobile still shows nothing for other suppliers, because their cached flags are stale (Phase 3); mobile never gated on them.
- **Submit.** US Foods now confirms its lines (`confirms_lines_before_submit?` → true), so our cached "out" flag no longer stops a US Foods order at pre-validation.
  - If the chef places an item US Foods shows out, US Foods fills or shorts it, and the existing exception email reports it.
  - Discontinued (1102/1104/1106) still stops the order at checkout (1.5).
- **Checked in the browser** (local dev, scratch orders created and then deleted):
  - Desktop: the US Foods card read "Ready" with Submit on and the amber row and banner; the CW card had a red row, "Remove it to submit", and Submit off.
  - Mobile: the amber note showed on the US Foods row.

**Found while building 1.3**
- **The desktop review page blocks Submit for ANY item our cache flags out of stock** (`canSubmit … && hasNoUnavailable`), at every supplier. With ~2,600 stale flags (WCW 1,492 available at WCW), chefs can be forced to remove items the supplier has. That makes plan Phase 3.2 (stale-flag cleanup) more urgent.
- **The mobile review never showed out-of-stock at all,** and never gated on it.

## Specs

- `spec/services/scrapers/us_foods_ordering_spec.rb` (23):
  - PC refused before any US Foods call; rejected cart update stops;
  - clear fails closed three ways;
  - line check: pass (submits US Foods' copy), missing, quantity, extra, eaches, unreadable;
  - submit: SUBMITTING without a number → orderId, a tandem number, still in cart, a timeout that went through, unconfirmed, another order's answer, a non-open order;
  - 1104 named with the cart emptied; 1106 on a dry run; no prices.
- `spec/services/scrapers/us_foods_api_ordering_spec.rb` (6): no fallback to our copy, never another order, our copy returned; 401 renew-and-retry; expired renew; unknown expiry doesn't renew.
- `spec/services/import_supplier_products_service_spec.rb` (+3): reinstated → in stock (catalog, nil stock); reinstated but the scrape says out → stays out; reinstated by refresh → in stock.
- **25 of the 28 new examples fail on the old code.** The other 3 are guards.

## What did not work / was wrong in the plan

- **Plan 1.2 said "require `tandemOrderNumber`".** That would have parked EVERY live US Foods order as unconfirmed: the number doesn't exist at submit time. Checked against prod (22 orders) and order 482's log before building.
- **The audit's "fake confirmation with our own id" (A2) was half right.** The orderId is US Foods' own id, generated by US Foods when the cart is created, not ours. The real gap was that ANY answer counted as placed.

## Open items

- **No delivery-date check in the line check.** US Foods may move a date legitimately; unverified, so not added.
- **The service still shows `ScrapingError` text** as "Order failed: …" (Phase 5 rewrites the wording).
- **Carmin's model (Oct 19):** catch "went out between 8 AM and order time" at the PRICE CHECK, before submit. Not in the plan yet; to be proposed as a step.
- 1.3 specs:
  - `us_foods_ordering_spec.rb` "#scrape_prices live stock": in, out (all reserved), eaches for PC, non-"R" unknown, no product unknown, class flags.
  - `price_verification_service_spec.rb` "live stock at the price check": out without a price change, back in, nil unchanged, out kept with a price change, placeholder never clears "out".
  - `spec/requests/review_stock_warning_spec.rb`: USF warns on desktop and mobile; poll `blocking: false`; discontinued blocks; CW still blocks; no mobile notice for CW.
- `confirms_lines_before_submit_spec.rb`: US Foods → true.
