# Screens and alerts after a stop, every supplier (plan Phase 5)

**Date:** 2026-10-19 · **Branch:** `claude/charming-grothendieck-c1c08e` · **Status:** built and tested, NOT committed, NOT pushed · **Plan:** `docs/plan-out-of-stock-all-suppliers.md` Phase 5 · **Message audit:** `docs/fix-cw-out-of-stock-message.md` (B and C)

## What Carmin asked for

When an order stops, the chef can see why and fix it fast, especially on the phone. Failures the chef can fix stay in the app with no email; email goes to chef and owner only when an order looked placed and then turned out inconsistent (Oct 3). Order 483 (Oct 19) showed the gaps: a 30-line order with the refused item somewhere in the middle, a "−" that stopped at 1 so the walnuts couldn't come off, and a quantity change saved 0.5 s after Submit.

## What changed

### 1. A crash after the submit went out is "check before reordering", never "failed"

Every scraper calls `submit_sent!` right before the request that places a live order (Chef's Warehouse, US Foods, Premiere Produce, Sysco, What Chefs Want, Performance). After that point:

- An unexpected error (a bug, a timeout in code that hasn't been taught about it, a failed save of the placed order) makes the order **unconfirmed**: `pending_manual`, "We sent this order to X, then something went wrong before it confirmed, so it may or may not have gone through. Check X before reordering, so it is not placed twice.", plus the chef + owner email. Before, it was `failed`, and Fix & Resubmit could place it twice.
- A clear refusal raises the new `NotPlacedError` and stays `failed` (retryable): CW "rejected the order" / "still in the cart", US Foods "still in the cart", PPO "rejected the order", WCW "refused the order", Performance "rejected the order", Sysco's refused submit. A login turned away at submit (Sysco 401/403, Performance 401/203) is a refusal too, with "Reconnect X, then resubmit".

**PlaceOrderJob's own rescue** follows the same rule. It also never touches a placed or cancelled order, nor an outcome the service already wrote during the run. That rescue once flipped submitted order 102 to failed.

### 2. No edits while an order is being placed

Submit (single, batch, accepting price changes) flips the order to "processing" under the order's row lock, re-checking that it can still be placed (`Order#start_placement!`). Every item add, quantity change, removal and order edit runs under the same lock and re-checks that the order is editable (`Order#edit_while_editable`). An edit that arrives after Submit gets "This order is being placed, so it can't be changed now." and changes nothing. A second Submit enqueues nothing.

So a quick tap before Submit isn't lost: the order page sends any change still waiting on its 500 ms debounce, waits for it, then submits. Checked in the browser: "+" then Submit within the debounce, and the order went out with the new quantity.

### 3. The refused line is easy to find and fix

- **Phone and desktop order pages:** refused lines come first.
- **Desktop:** refused lines are red with "Not taken by X: <reason>" and a red "Not taken" badge. Before, they showed a grey "Failed" badge with no reason. This applies before and after Fix & Resubmit.
- **"−" at 1** asks "Remove?" and a second tap within 3 s removes the line, on every line of a reopened order. Before, it did nothing (order 483).
- **Pre-order validation stops** (out of stock, discontinued) now mark their lines red with the reason, like a refusal at the cart. Before, they marked nothing.

### 4. Batch progress (after Submit All)

- Orders that need review (cart mismatch, price change) get the reason and **Fix & Resubmit**. Before, only `failed` did.
- Badges read "Not placed", "Not placed: review" or "Check supplier", instead of "Failed" or a raw status.
- An order that needs review no longer also counts as "still waiting to be submitted".

### 5. Messages (B table in `fix-cw-out-of-stock-message.md`)

| Stop | Now |
|---|---|
| Pre-order validation | "Not placed. X can't supply 1 item: Walnut Halves — out of stock. Remove or change it, then resubmit." / "…EnPlace couldn't sign in to X. Reconnect X under Suppliers…" (was "Pre-order validation failed: … (status: expired)") |
| Price changes | "Not placed yet. X prices changed on 2 items: Walnut Halves $42.10 → $45.80; … Resubmit to order at the new prices, or remove them." |
| Sign-in code (2FA) | "Not placed yet. X needs a sign-in code. Enter the code when EnPlace asks for it (or reconnect X under Suppliers), then resubmit." |
| No connection | "Not placed. EnPlace isn't connected to X for this restaurant, or the login stopped working. Reconnect X under Suppliers, then resubmit." |
| Minimum | "Not placed. X's minimum is $400.00 and this order is $312.10. Add $87.90 more, then resubmit." |
| Every line failed for one technical reason | "Not placed. Couldn't reach X's cart, and nothing was ordered. Try again in a minute." (instead of listing 30 lines with "HTTP 503") |
| Account hold | "Not placed. X has a hold on your account: <banner>. Call your X rep; EnPlace can't clear this." |
| Robot check | "Not placed. X's site asked for a robot check EnPlace can't answer. Place this order on X's site or app." |
| Delivery date | Starts with "Not placed."; Sysco's now reads "Sysco won't deliver on Wed Oct 7. The earliest it will is Wed Sep 30. Change the delivery date and resubmit." (was ISO dates and a list) |
| Anything else before the submit | "Not placed. Something went wrong talking to X, and nothing was ordered. Try again; if it fails twice, order on X's site." The technical text stays in the logs. Messages already written for chefs ("Couldn't read the US Foods cart, so nothing was ordered. Try again.") show as written. |

**Titles:** a sign-in code or a robot check is `pending_manual`, but nothing was sent. The order page now titles it "Order NOT placed" and the red bar says "NOT placed. Tap to fix", instead of "Check with the supplier before reordering". Only an unconfirmed submit keeps that wording.

## Ordering impact

- **No gate loosened.** The only order-status change goes the safe way: an unexpected error after the submit went out is `pending_manual` (not retryable, chef checks the supplier) instead of `failed` (retryable).
- **Edits can no longer land during placement.** The page sends any pending change before Submit.
- Everything else is display and wording.

## What did not work, or changed from the plan

- **B/460 proposed `failed` for cart mismatches** so every screen offers a retry. Kept `pending_review` and gave batch progress the retry button instead (the plan's Phase 5 line). A mismatch still reads as "needs your review".
- **B/275/498/545 proposed a retryable status for sign-in codes and robot checks.** Kept `pending_manual`, because the 2FA flow re-queues the order once the code is entered (`two_factor_channel.rb`). Fixed the misleading title instead, keyed on the message starting with "Not placed".
- **Legacy browser checkout paths** (CW `:1772`, PPO `:2136` / `:4760`, US Foods `checkout_BROWSER`) are not marked with `submit_sent!`. Live `checkout` doesn't call them.
- **`SplitOrderService`** still flips orders to processing without the lock. It's rare, and its orders are new.
- **Browser check:** the first test Submit ran the real pre-check, which tried to restore the dev chef's Chef's Warehouse session (it had expired; dev always dry-runs). That is existing dev behavior, noted here.

## Checked in the browser

A private copy of the dev database, migrated to this branch, at phone width and on desktop, in dark mode. It had a failed Chef's Warehouse order with 6 lines (refused line created last) and a Sysco order needing review.

- Phone: refused line first, red, with its reason.
- Fix & Resubmit: "−" from 2 to 1, then "Remove?", then removed (5 lines in the database).
- "+" then Submit within the debounce: quantity 3 saved before the order flipped.
- Batch progress: "Not placed: review", the reason, Fix & Resubmit, and no "waiting to be submitted".
- Desktop: refused row first, red, "Not taken by Chef's Warehouse: Out of stock", red badge.

The copy and the temporary sign-in were dropped afterwards. The shared dev database was not touched.

## Specs

- New: `spec/requests/order_edit_lock_spec.rb` (incl. the race at model level), `spec/requests/order_failure_screens_spec.rb`.
- Changed: `order_placement_service_spec.rb` (messages, safety net), `place_order_job_spec.rb` (rescue rules); scraper specs now expect `NotPlacedError` and `submit_sent?`; Sysco's delivery wording.
- 27 of the 75 examples in the four main spec files above fail on the Phase 4 commit (`8a0e2ab`). The rest pin behavior that must not change.
- Full suite: 1,974 examples, 0 failures (branch test database).

## Open items

- The desktop failure notice's message text (`text-red-700`) is dim in dark mode, as before. The phone uses the same class.
- Performance and Sysco read-back rules after an unclear submit are unverified live (see `fix-phase4-checkout-checks.md`).
