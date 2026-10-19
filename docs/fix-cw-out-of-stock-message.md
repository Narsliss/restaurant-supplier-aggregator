# Chef's Warehouse out-of-stock: name the item, and audit of other "not placed" messages

**Date:** 2026-10-19 · **Status:** Phase 1 built, full suite green (1,770 examples), NOT committed or deployed · Phase 2 is an audit only, with nothing changed · **Order placement:** TOUCHED (CW add-to-cart, CW pre-checkout cart check, the cart-mismatch message). No gate loosened; every changed path still submits nothing.

## What happened (order 483, Oct 19 2026, D'oro)

Chef Michael ordered from Chef's Warehouse. CW's `/web-api/cart/add` answered:

```
{"totalCount"=>29, "success"=>true, "validationMessages"=>["Out of stock - (NW101B) Walnut Halves"]}
```

CW left the walnuts out of the cart. `ChefsWarehouseScraper#add_to_cart` read `success: true` as "everything added", so nothing was reported as failed. The cart check (`verify_cart_matches!`) then found NW101B missing and raised `CartMismatchError`. The chef saw:

> Supplier cart did not match your order, so we did not submit it. This usually means a leftover item from a previous attempt. Please review and try again.

He tapped Fix & Resubmit twice, and it failed the same way each time. Nothing told him which item. Nothing was submitted, which is correct. The owner thought the chef was making the failure up. The failure was real, but our message misled them both. D'oro's CW cart still held $1,402.15 of lines afterwards.

Worker logs, last 30 days: 14 cart/add responses. 11 had empty `validationMessages`, and the other 3 were this Walnut message (order 483's three attempts). No other CW message wording has been seen.

## Phase 1: what changed

1. **CW `add_to_cart` reads `validationMessages`** (`chefs_warehouse_scraper.rb`, `lines_cw_refused`).
   - A message like `Out of stock - (SKU) Name` that names a line we sent becomes a failed item `{sku:, name:, error: "Out of stock"}`. It is matched by normalized SKU (`JDE_` prefix, `-800001` suffix and case don't matter).
   - Another wording that contains `(SKU)` for one of our lines also fails that line, with CW's whole text as the reason.
   - A message that names none of our lines is logged and ignored. `verify_cart_matches!` still stops the order if a line is missing.
   - The existing `raise_for_items_not_added!` path then stops the whole order. The chef sees: "Not placed. Chef's Warehouse couldn't take 1 item: Walnut Halves — Out of stock. Remove or change it and resubmit." Every line is kept, the walnuts are marked failed (red on the mobile item list, "Problem:" in the email), and nothing is submitted.
   - The `success: false` and exception paths now report OUR sku and name instead of CW's `JDE_…-800001` code. Before, the order item couldn't be found to mark it failed, and the chef saw "SKU JDE_NW101B-800001".
2. **Cart-mismatch message** (`order_placement_service.rb`, `handle_cart_mismatch_error`).
   - When every discrepancy is `missing_from_cart`, the items are looked up on the order (case-insensitive SKU) and the error goes through the same item-unavailable path: status `failed`, items marked failed, message names them with "left out of the cart, no reason given". Because no reason was given, the item is not marked out of stock.
   - "This usually means a leftover item from a previous attempt" now appears only when every discrepancy is `extra_in_cart`. Quantity, unit or mixed differences get the plain "Supplier cart did not match your order, so we did not submit it. Please review and try again."
3. **CW cart emptied when the order stops before checkout** (`discard_cart_after_stop`): on a `verify_cart_matches!` mismatch, and when `add_to_cart` has any failed line. The price-refresh re-check already did this and now uses the same helper.
   - It's best effort: if emptying fails, it's logged and the original stop still raises. The next attempt's `clear_cart` fails closed on a dirty cart.
   - The cart only holds this attempt's lines, since placement already empties it before adding.
   - The delivery date is no longer set when the order is going to stop.

### Ordering impact

- **Same outcome, better reason.** An order CW only partly accepts now stops at add-to-cart, before the cart check. The outcome is the same as before (stopped, nothing sent); only the reason is new.
- **Status change.** An all-missing cart mismatch now ends `failed` instead of `pending_review`. Both statuses can be retried, both show the red bar, and both are eligible for the not-placed alert.
- **New risk: fails closed.** A harmless CW notice naming a line CW actually DID add would now stop the order. None seen in 30 days of logs.

### Specs

- `chefs_warehouse_scraper_spec.rb`:
  - an out-of-stock message becomes a named failed line, the cart is emptied, and no delivery date is set
  - JDE/suffix/lowercase codes still match
  - another wording keeps CW's text
  - a message naming none of our lines changes nothing
  - all lines refused raises naming each
  - `success: false` names our lines
  - a mismatch empties the cart, still raises when the cart won't empty, and leaves a matching cart alone
  - an off-guide refusal empties the cart
- `order_placement_service_spec.rb`:
  - **order 483 end to end through the real CW scraper**: `failed`, exact message, both lines kept, walnuts marked failed with "Out of stock", nothing submitted, cart emptied twice (before adding, after stopping)
  - an all-missing mismatch names the item and doesn't mark it out of stock
  - a quantity mismatch doesn't say "leftover"
  - an extra-in-cart mismatch still does
- All 11 new examples fail against the old code.

### What did not work / not done

- The parser can't tell "CW refused this line" from "CW added it but wants to tell us something". Any message naming one of our lines fails it (closed). If CW starts sending informational notices, they will stop orders with CW's own text as the reason.
- `totalCount` (29) is not compared with the lines sent. Its meaning isn't confirmed, and the cart check already catches a missing line.
- Order 483's CW cart (D'oro, $1,402.15) was not touched. It is emptied on the next CW order attempt, or the chef can empty it on CW's site.

## Follow-up the same day: the 4th attempt, and why nothing said "out of stock" beforehand

All times ET, from worker/web logs and read-only prod queries.

**What the chef did.**
- **12:18** Order 483 created (27 lines).
- **12:19, 12:21, 12:22** Three attempts. Each time CW refused only Walnut Halves (NW101B), and each time the chef saw "leftover item".
- **1:47** He reopened the order and tapped "−" on the walnuts (`PATCH order_items/2749` quantity 1, twice, plus one "+" then "−"). On mobile, "−" stops at 1 (`order_edit_controller.js` `decrementItem`: `if (current <= 1) return`). The only Remove button on the mobile order page is for items flagged as refused, and the cart-mismatch path never flagged the walnuts. **He had no way to take them off.**
- **1:47** Submit. CW now refused three: Red Fresno Chilis (PRD0044RP), Leeks (SW88700), Walnut Halves. The message was "leftover item" again.
- **1:51** He cancelled order 483 and ordered in CW's own app.
- **Note:** this attempt left the other 24 lines in D'oro's CW cart (live code doesn't empty it on a mismatch). CW's app shares that cart, so his CW-app order probably started from those 24 lines. Worth checking it for doubled lines.

**Why the app didn't show them as out of stock before checkout.**
1. **The 8 AM CW sync never covers D'oro.** `SyncAllListsJob` syncs ONE login per supplier per organization (`sync_all_lists_job.rb`, `one_credential_per_supplier_per_org`).
   - Org 7 has 9 CW logins across alfios (9), Noche (10) and D'oro (16). The job picks Alfio's credential 72, whose restaurant picker covers only alfios and Noche.
   - D'oro's logins (119 Michael, 121 Cody, 135 Alfio's D'oro login) are never synced in the morning.
   - D'oro's CW lists (D'oro Full Order Guide 165, Previously Purchased 164, Ultimate Bar Guide 166) were last synced **Sat Oct 17 8:03 AM** and are stuck in `sync_status: "syncing"`.
   - The walnut rows on D'oro's lists were last updated Sep 25.
2. **The walnuts sold out between ~8 AM and 12:19 PM. It wasn't a D'oro-only gap.**
   - Alfio's 8:02 AM sync read the walnuts on alfios' guides and left them in stock. Those rows didn't change, so CW's count was above 0. The shared walnut row (supplier_product 244) was also written `in_stock: true` at 8:04 AM.
   - Live read-only check at 2:31 PM on Alfio's CW login (ship-to 614969): the walnuts' `variant.inStock` is **0.0**, and our parser returns `in_stock: false`. Flour reads 36.0 → true.
   - So the parser reads the right field, and Alfio's account sees the same stock as D'oro (Carmin also saw the walnuts out of stock on Alfio's login).
   - Point 1 (D'oro not synced) is real and leaves D'oro's guide prices and items stale, but it is **not** why the walnuts weren't flagged.
3. **Chilis and leeks really did go out during the day.** Both are off-guide and were added to D'oro's list at 12:15-12:16. Their product rows were last touched by the 6 AM catalog job, which doesn't read stock (`scrape_prices` writes `in_stock: true`, `chefs_warehouse_scraper.rb:208`). CW **accepted** both at 12:22 and **refused** both at 1:47, so they went out of stock between 12:22 and 1:47 PM.
4. **No morning snapshot can promise 2 PM stock.** Two of the three sold out during lunch.
   - The order builder does show "Out of stock" from the cache (`_order_builder_mobile_card.html.erb:92`), but the cache is only as fresh as the last sync.
   - Since Oct 3, CW orders skip the cached stock check (supplier decides).
   - What protects the chef is: a live ask at order time, a named refusal at checkout (Phase 1), and a one-tap way to drop the item.
   - Verified live: CW's price call (`/web-api/product/prices`, even with `checkAvailabilityFlag: true`) returns **no** stock field. The order-guide call does (`variant.inStock`, a count), and so does catalog search (`parse_search_product`, same field). A live check has to use those.

**What Phase 1 changes for this exact case.** The first attempt would have said "Not placed. Chef's Warehouse couldn't take 1 item: Walnut Halves — Out of stock." The walnuts would have been flagged red, and after Fix & Resubmit they'd have a Remove button (existing behavior for flagged items, `order_failure_fix_flow_spec.rb`). The 1:47 attempt would have named all three. A new spec covers the three-item response.

**New open items from this.**
- Sync every restaurant's CW login, not one per organization, and find why lists 164-166 are stuck in "syncing".
- Mobile: let the chef remove any line on a reopened order (today "−" silently stops at 1, and Remove appears only on flagged lines).
- Live CW stock check when the chef reviews or submits (the guide endpoint's per-item `inStock` count, or the price call's availability if the reply has one).
- A quantity PATCH was accepted 0.5 s after Submit (17:47:39.626 UTC). It was the same value this time, but edits shouldn't land while an order is being placed.

## Phase 2: audit (report only, nothing changed)

### A. Other suppliers: success reported while a line is dropped or changed

Read-only review by three sub-agents. I re-checked the top claim for each supplier in the code. "Inferred" = the code allows it, but whether the supplier really does it is unconfirmed. Ordered worst first.

**Ships short, or the wrong line ships. Today the chef sees "submitted".**

| # | Supplier | Where | What the supplier sends / we ignore | Proposed fix |
|---|---|---|---|---|
| A1 | US Foods | `us_foods_scraper.rb:1207-1215`, `us_foods_api.rb:500-508` | `add_to_cart` always returns `failed: []`. A failed cart PUT (`put_json` → nil on non-2xx, empty or bad JSON) **falls back to our own local copy of the order**, so the `unless result` guard can't fire. Checkout then reads lines and subtotal from that copy and submits it (`:2148`, `:2204`). Nothing compares USF's `orderItems` to what we sent, and nothing reads `productExceptionCount` / `orderExceptions` / `tandemDeleted` before submit. A line USF drops entirely is never alerted, not even after submit (the exception check only sees lines still on the order). | Raise on a nil PUT; never fall back. Add `verify_cart_matches!`: re-GET the order, compare SKU + `unitsOrdered`/`eachesOrdered`, and name the item. Keep `confirms_lines_before_submit?` **false** for USF until stock is covered, so the cached stock check stays on. |
| A2 | US Foods | `us_foods_scraper.rb:2204-2212` | Any 2xx hash from submit counts as placed. The confirmation falls back to `result['orderId'] \|\| order['orderId']`, our own id, so it can look like a confirmation it isn't. `orderStatus` and the returned lines are not checked. | Require `tandemOrderNumber` and a submitted status; otherwise OrderUnconfirmedError. |
| A3 | US Foods | `us_foods_api.rb:480-482` | We send `eachesOrdered: 0, unitsOrdered: qty` and ignore `uom`. A piece (PC) line would go as cases (inferred: depends on the PC toggle being offered for USF items with a split price). | Send eaches for PC, or refuse PC at USF with a clear message until verified live. |
| A4 | US Foods | `us_foods_scraper.rb:2241`, `:2165-2170` | `clear_order`'s result is ignored, so leftovers can stay and ship as extras. Checkout re-fetches prices but drops `error_number` (1102/1104/1106), so a discontinued line is priced $0 and submitted. | Fail closed on a failed clear; fail any line with a price error, using the existing `price_error` wording. |
| A5 | Sysco | `sysco_scraper.rb:639-648, 658-664` | It checks only that each SKU is **present** after `updateOrderV2`. Submit then sends **Sysco's echoed `qty`** with `soldAs: 'cs'`, so if Sysco caps 5 to 2, we submit 2 (inferred trigger). Per-line `qty`/`soldAs`/price are never compared. | Compare the echoed qty/unit with the order and fail the line ("Sysco accepted 2 of 5"). Submit the quantity we asked for. |
| A6 | Sysco | `sysco_scraper.rb:846-870`, `:3298` | Any non-null `submitOrderV2` counts as placed. The confirming lookup filters `hasHeaderErrors: false`, so an errored order isn't found and the confirmation falls back to our draft id. No stock field is read anywhere, and the cached check is off for Sysco (inferred). | Require the order found, not OPEN, with the expected line count; otherwise OrderUnconfirmedError. |
| A7 | Premiere Produce | `premiere_produce_one_scraper.rb:274-279` | No line check (`confirms_lines_before_submit?` false). The `updateCart` answer, which already returns each line's pack quantity and item id, is only checked for presence. PPO's own `validate_order` (alerts, `can_place_order`, per-line quantity) is **defined but never called** (`premiere_produce_one_api.rb:311`). `availability_status` is fetched and ignored (`:384-392`). | Add `verify_cart_matches!` from the `updateCart` lines plus `validate_order`. Stop on `can_place_order: false` or any alert, quoting `alert_message`. |
| A8 | Premiere Produce | `:252`, `:342-361`, `:389-392` | SKU→pack map is "last match wins", so the wrong pack is possible (inferred). `clear_cart` swallows errors, so leftovers can ship. The order total ignores quantity (2 × $12.50 recorded as $12.50). | Use the stored pack uuid; fail closed on clear; multiply by `pack_quantity_at_order`. |
| A9 | What Chefs Want | `what_chefs_want_scraper.rb:698-703`, spec `what_chefs_want_cart_check_spec.rb:102` | The cart check accepts our SKU if it matches **any** variant code of the product, so a case-for-lb swap passes (inferred). The guide's `isOutOfStock`/`isUnavailable` are ignored while the cached check is off. | When a product has several variants, require the exact one. Fail flagged lines with that reason. |
| A10 | Performance | `performance_scraper.rb:400-430`, `:315-322` | The cart check compares only TotalLines, TotalQuantity and date. A same-count swap (a leftover line next to a silently uncreated one; `clear_cart` only warns, `:378`) or a case/each mix passes. `TotalOrderPrice` isn't compared. The comment at `:391` claims per-line read-back that the code doesn't do. | Compare `TotalOrderPrice`, read echoed lines, fail closed on clear. |

**The CW pattern: a reason the supplier gave is dropped, so the chef gets a vague or wrong message. The order does stop.**

| # | Supplier | Where | Today | Proposed |
|---|---|---|---|---|
| A11 | What Chefs Want | `what_chefs_want_api.rb:508-511` | GraphQL `errors` returned **alongside data** are logged and dropped, so the cart check says "didn't add it to the cart" without WCW's reason. Closest to the walnut bug. | Keep the error text per item and use it as the reason. |
| A12 | Sysco | `sysco_scraper.rb:3154-3162`, `:589`, `:686`, `:675` | Errors that come with data are dropped. Whole-cart failures raise ScrapingError, which shows "Order failed: … SKUs: 123, 456" with no names. | Attach errors to their SKU; raise ItemUnavailableError with the `failed_items` already built. |
| A13 | Premiere Produce | `premiere_produce_one_scraper.rb:276`, `premiere_produce_one_api.rb:438-440` | A rejected `updateCart` records `{ sku: <item name>, error: 'API rejected' }`. The chef sees "SKU Limes — API rejected", and no line is marked because the SKU lookup fails. | Keep the sku and name, and show PPO's error text. |
| A14 | Performance | `performance_scraper.rb:315`, `:473-475` | Warnings on a successful add are ignored (inferred). `RejectedMessage` is ignored, so the chef sees "Performance rejected the order: IsSuccess false". A dropped line becomes `line_count`, which gives the vague mismatch text. | Show `RejectedMessage`. Re-read TotalLines after each single-line add, to name the item that didn't take. |
| A15 | What Chefs Want | `what_chefs_want_scraper.rb:221` → service | The quantity mismatch carries both quantities, but the chef sees only "Supplier cart did not match… review". | Covered by the B/460 wording proposal. |

**Double-order risk (not ship-short).** At US Foods (`us_foods_api.rb:762-766`), Sysco, Performance and What Chefs Want (`what_chefs_want_api.rb:501-521`), a submit timeout or non-2xx lands in `handle_generic_error`, which sets `failed` (retryable). The supplier may already have the order, so a chef who taps Fix & Resubmit can place it twice. CW and PPO already turn this into OrderUnconfirmedError (`pending_manual`, "check before reordering"). Fix: same for the other four, or the generic-handler change in B/567.

**Not production, but worth knowing.** Outside production, Performance's `add_to_cart` marks everything "added" and its dry-run reads whatever draft is open on the customer's real Performance account (`active_order_id!` fallback). A future staging environment running as `production` would write real carts.

**Spec coverage.** None for USF `add_to_cart`/`clear_cart`/`checkout`/`submit_order`, Sysco quantity/unit/partial errors/post-submit status, PPO line drops/totals, WCW unit/stock/error text, or Performance price totals/swaps/`RejectedMessage`.

### B. The 14 `error_message:` assignments in `order_placement_service.rb`

Line numbers are after Phase 1. "Title" is what `order_failure_notice` puts above the message.

| Line | Status | Today's text | Problems | Proposed |
|---|---|---|---|---|
| 238 | failed | "Pre-order validation failed: …" + joined errors | "Pre-order validation" is jargon. Inner texts leak: "(status: expired)", "Failed to connect to X: #{e.message}", "Validation failed: #{e.message}", "is out of stock (cached data)". The item is NOT marked failed, although the error carries `item_id`, so no red item. | Drop the prefix and start with "Not placed." Rewrite each inner message per type (below). Mark items failed using `item_id`. |
| 256 | pending_review | "3 item(s) have price changes. Review required." | Doesn't say which items or where to review. | "Not placed yet. Chef's Warehouse prices changed on 3 items: Walnut Halves $42.10 → $45.80, … Resubmit to order at the new prices, or remove them." |
| 275 | pending_manual | "Two-factor authentication required to validate order." | Title reads "Check with the supplier before reordering", which is wrong because nothing was sent. pending_manual can't be retried, so there's no Fix & Resubmit. "Two-factor authentication" is jargon. | "Not placed. US Foods needs a new sign-in code. Reconnect US Foods under Suppliers, then resubmit." Use a status that can be retried. |
| 333 | failed | "No active credentials for US Foods" | "credentials" is jargon, and the chef isn't told what to do. (PlaceOrderJob's rescue then rewrites it with the same text.) | "Not placed. EnPlace isn't connected to US Foods for this restaurant (or the login stopped working). Reconnect it under Suppliers, then resubmit." |
| 359 | failed | "Order minimum not met. Minimum: $400.00, Current: $312.10. Add $87.90 more to proceed." | Accurate and actionable. Missing "Not placed" and the supplier name. (US Foods' old browser `handle_checkout_error` would show "Current: $0.00", but it is dead code: `us_foods_scraper.rb:3988`, never called.) | "Not placed. Chef's Warehouse's minimum is $400.00 and this order is $312.10. Add $87.90 more, then resubmit." |
| 387 | failed | "Not placed. CW couldn't take 1 item: Walnut Halves — Out of stock. Remove or change it and resubmit." | Good shape. Reasons can be technical: CW exception path `e.message` ("Net::ReadTimeout…"), "API rejected", Performance "HTTP 503". When the whole request failed, all 30 lines are listed. PPO's rejected `updateCart` puts the item NAME in the sku field, so the chef sees "SKU Limes — API rejected" (A13). An empty `items` list would read "couldn't take 0 items: ." (only dead USF browser code raises that today). | Keep for real refusals. If every line failed for a technical reason, say "Not placed. Couldn't reach Chef's Warehouse's cart. Nothing was ordered — try again in a minute." Never build the message from an empty list. |
| 430 | pending_review | "Prices changed for N item(s). Review required." | Unreachable today (defensive). Same problems as 256. | Same wording as 256. |
| 460 | pending_review | "Supplier cart did not match… [leftover…] Please review and try again." | Phase 1 fixed the all-missing case. Quantity, unit and extra lines still aren't named. Performance's totals check can't name a line. pending_review gets no Edit & Retry button on the batch-progress screen (C). | Name each line: "CW's cart had 1 Walnut Halves, you ordered 2", "…had it as a case, you ordered pieces", "…had an item that isn't on this order (SKU X); we emptied the cart". Use `failed` so every screen offers the retry. |
| 482 | failed | "Account issue: #{error.message}" | The supplier's raw banner text, with "Account issue:" in front. It can be retried, but a retry fails until the hold is cleared. (Today only dead USF browser code raises AccountHoldError, so this is practically unreachable.) | "Not placed. US Foods has a hold on your account: <banner>. Call your US Foods rep. EnPlace can't clear this." |
| 498 | pending_manual | "CAPTCHA detected. Manual order placement required." | Jargon. Title says "check before reordering" though nothing was sent. Can't be retried. | "Not placed. US Foods' site asked for a robot check we can't answer. Place this order on US Foods' site or app." |
| 515 | failed | `error.message` (delivery) | PPO's texts are already written for chefs. Sysco's: "not accepting delivery on 2026-10-21 for this account. Earliest currently-available date is 2026-10-22. Available: …" uses ISO dates and a list. US Foods' browser path passes raw page text. | "Not placed. Sysco won't deliver on Tue Oct 21. The earliest is Wed Oct 22. Change the delivery date and resubmit." |
| 530 | pending_manual | `error.message` (unconfirmed) | CW's and PPO's texts are good ("…Check Chef's Warehouse before reordering, so it is not placed twice."). The email goes out, which is correct per the rule. | Keep. |
| 545 | pending_manual | "Two-factor authentication required. Please enter the verification code." | Same title and retry problem as 275, and it doesn't say where to enter the code. | Same as 275, naming where the code was sent if known. |
| 567 | failed | "Order failed: #{error.message}" | Leaks anything: "undefined method `[]' for nil", "Net::ReadTimeout", "Checkout timeout", "Cart is empty", "CW cart could not be emptied — 2 line(s) remain after clear". Some ScrapingError texts are already written for chefs but get "Order failed:" in front. **Safety:** an error raised inside a LIVE `scraper.checkout` is marked `failed` (retryable) although the supplier may have the order. Only CW (and PPO, per its doc) turns that into OrderUnconfirmedError. | Chef-written errors (an explicit `chef_message`) show as-is. Anything else before checkout becomes "Not placed. Something went wrong talking to Chef's Warehouse, and nothing was ordered. Try again; if it fails twice, order on their site." Anything else raised during a live checkout becomes `pending_manual` + "check before reordering", unless the scraper says nothing was sent. |

Also outside the service: `PlaceOrderJob#perform`'s rescue writes raw `e.message` (`place_order_job.rb`, `order&.update!(status: "failed", error_message: e.message)`).

### C. How the message is shown

- **Mobile order page** (`orders/show.html+mobile.erb`): a red box with the title and message (line ~94), then Fix & Resubmit, then the items. Failed items get a red border, "Not taken by <Supplier>: <reason>", and a Remove button once the order is reopened (line ~172). **Gaps:**
  - The failed item isn't moved to the top. Order 483 had 30 lines, so the chef scrolls to find it.
  - Only items with status `failed` are marked. The pre-validation path (238) and the remaining cart-mismatch kinds (460) mark nothing. Before Phase 1, order 483 marked nothing.
- **Desktop order page** (`orders/show.html.erb:421-426, 470-475`): a failed item shows only a grey "Failed" badge, with no reason and no red.
- **Red bar** (`shared/_unplaced_orders_bar.html.erb`): "<Supplier> · Tue Oct 21: NOT placed. Tap to fix". It's a pointer only, with no reason. For pending_manual it says "Check with <Supplier> before reordering", which is wrong for 2FA/CAPTCHA (see 275/498/545).
- **Batch progress after Submit All** (`orders/batch_progress.html.erb:185,192`, `batch_progress_controller.js:136`): the error and the Edit & Retry button are only rendered for `failed`. The poll then reveals the message for any status, but never the retry button for `pending_review`. There's no mobile variant.
- **Not-placed email** (`order_mailer/order_not_placed.html.erb`): "What happened" shows `error_message`, and failed items get "Problem: <reason>". Fine. It only goes out when the chef didn't see the failure (rule kept).

## Open items

- Phase 2 changes wait for Carmin, one decision at a time. Suggested order:
  1. US Foods line check (A1/A2): the only supplier where a dropped line is never seen, before or after submit.
  2. Submit timeouts → "check before reordering" (double-order risk).
  3. PPO line check (A7).
  4. Sysco quantity echo (A5).
  5. The message rewrites (B).
  6. Desktop failed-item marking and failed-item-first on mobile (C).
- The CW parser fails closed on any message naming one of our lines. Revisit if CW starts sending notices for lines it did add.
- Commit/push waits for Carmin's OK.
