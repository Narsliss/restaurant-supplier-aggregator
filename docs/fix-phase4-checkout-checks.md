# Checkout checks for Sysco, What Chefs Want and Performance (plan Phase 4)

**Date:** 2026-10-19 · **Branch:** `claude/charming-grothendieck-c1c08e` · **Status:** built and tested, NOT committed, NOT pushed · **Plan:** `docs/plan-out-of-stock-all-suppliers.md` Phase 4

## What Carmin asked for

Never ship short (Oct 3): when a supplier won't take an item, the whole order stops and the chef is told which item and why. No made-up confirmations. Failures the chef can fix are shown in the app. Email (chef + owner) only goes out when an order looked placed and then turned out inconsistent. Chef's Warehouse, US Foods and Premiere Produce were brought to this standard in Step 0 and Phases 1–2. This change does the same for the other three suppliers.

## What changed

### Sysco

| | Before | Now |
|---|---|---|
| Cart check before submit | Only checked that each item was on Sysco's draft | Sysco's echo of the draft must match the order line by line: same quantity, sold by the case, nothing extra. A difference deletes our draft and stops the order for review, with each difference named. |
| Quantity submitted | Sysco's echoed quantity | The chef's quantity |
| Sysco refuses an item at add ("Product 6081093 is not available for seller USBL") | "Order failed: Failed to add items to Sysco cart: updateOrderV2 failed: …" | The item is named in Sysco's words, like any refused item. The order stops and the item turns red. A refusal that names no item stays a plain failure. |
| After submit | Confirmation = the order's name if found, else the draft id, else a made-up `SYSCO-<timestamp>`. Nothing checked that Sysco took it. | Sysco's own order list must show the order **SUBMITTED** (up to 3 reads, 2 s apart) with at least as many lines as we sent. Otherwise the order is **unconfirmed**: `pending_manual`, plus the "check before reordering" email to chef and owner. The made-up confirmation is gone. |
| Submit times out, 5xx, or the connection drops | Plain failure. The chef could retry and order twice. | Sysco's order list decides: placed or unconfirmed. |
| Sysco refuses the submit (GraphQL error) | Plain failure | Still a plain failure with Sysco's reason, unless Sysco's list already shows the order submitted. Then it is checked like a normal submit, so a retry can't order twice. |

### What Chefs Want

| | Before | Now |
|---|---|---|
| Order guide read fails | Carried on with an empty guide, so every item took the off-guide path, attaching hidden copies of guide items to the restaurant's order form | Stops before anything is sent: "Couldn't read your What Chefs Want order guide, so nothing was sent: HTTP 502" |
| Item sold in several units (case, lb…) | Sent without a unit, so WCW picks the unit | Refused with the reason, before the cart is built. Read-only probe Oct 19: none of the 7 WCW logins' guides has one, and none of the 56 SKUs ordered in 60 days is one. Nobody is affected today. |
| WCW won't attach an off-guide item, or won't create the cart | "couldn't add it from its catalog" / "Failed to create draft order via API" | Same, plus WCW's own words |
| Submit times out, or answers non-2xx / unreadable | Plain failure (retryable) | **Unconfirmed** (check before reordering) |
| WCW refuses the submit (GraphQL error) | "Order submission failed: …" | "What Chefs Want refused the order: …" (still a plain failure) |

### Performance

| | Before | Now |
|---|---|---|
| A line PFG says yes to but doesn't hold (it has answered IsSuccess and created no line) | Caught only by the totals check before submit, which can't say which item | After each add the draft's line and case totals are read. A line that didn't land is named: "Performance didn't add it to the cart". The check is rebased on PFG's numbers after each item, so one missing line doesn't blame the next. If a read fails, the per-line check stands down and the totals check before submit still runs. |
| PFG refuses to delete the old draft | Logged; the order went on and the totals check refused it later | Stops before any add: "Couldn't empty your Performance cart, so nothing was sent: …" |
| PFG rejects the order | "Performance rejected the order: " + ErrorMessages (often empty) | Includes PFG's `RejectedMessage` |
| Submit times out, 5xx, or empty reply | Plain failure (retryable) | The order is read back (up to 3 times, 2 s apart). An order number plus the line and case totals checked before submit means placed. A number with other totals is unconfirmed, naming both. No number is unconfirmed. A login refusal (401/203) stays a plain failure. |

### All suppliers: cart mismatch wording

Before: "Supplier cart did not match your order, so we did not submit it. Please review and try again."

Now each difference is named, up to five, then "and N more":

> Supplier cart did not match your order, so we did not submit it: Sugar — Sysco had it by the piece, you ordered it by the case; Sysco's cart had 3 item(s), your order has 4; Sysco's cart is for Wed Oct 21, your order is for Thu Oct 22. Please review and try again.

The wording covers every discrepancy type the six scrapers report: quantity, unit, extra line, missing line, Performance's line count, case count and delivery date. Names come from the order's own lines, including Chef's Warehouse SKUs reported without `JDE_`. A missing-lines-only mismatch is still treated as a refusal that names the items (order 483).

## Ordering impact

- **Gates added, none loosened.** Every new path either stops before submit (nothing sent), or, after a submit that got no clear answer, reports **unconfirmed** unless the supplier's own record proves the order was placed.
- **Double-order path removed** for a submit that times out at Sysco, What Chefs Want or Performance. Before, the chef saw "failed" and could place it again.
- **No made-up confirmation** at Sysco.
- Sysco and Performance: a slow supplier adds up to about 4 s to the confirmation read.

## What did not work, or changed from the plan

- **WCW, "require the exact variant in the cart check":** the draft takes a multi-unit product with no unit, so there is no variant to require. Items with two or more units are refused at add instead.
- **WCW, "after a timeout, check `get_orders`":** WCW's orders query has no field that ties an order to our draft, so a match would be a guess. Unconfirmed instead: the chef checks.
- **Performance, "compare `TotalOrderPrice`":** skipped on purpose. Catch-weight items and price moves since the price check would stop good orders. Lines and cases are compared instead.
- **Performance, "compare the echoed lines":** PFG has no line read (header totals only), so the per-line check works on totals.
- **Sysco, "not OPEN":** tightened to SUBMITTED, the only status seen right after a submit (order #337). Anything else is unconfirmed. Statuses seen on the account: OPEN, SUBMITTED, DELIVERED, CANCELLED.
- **Sysco line count:** only *fewer* lines than sent is flagged. More is logged, because Sysco might add a line of its own (unverified).
- **Performance read-back:** couldn't be probed. On Oct 19 there were no open drafts, and no stored draft ids (order 335 now stores its order number). The rule rests on order #335: a draft has no OrderNumber, a submitted order has one. **Unverified:** whether PFG gives a *rejected* order a number. This only matters after a submit that got no answer, and the totals must also match.

## Read-only probes (prod, Oct 19)

- **What Chefs Want multi-unit:** 7 active logins, 0 multi-unit products in any guide, 0 of 56 recently ordered SKUs.
- **Sysco order list** (cred 58, the same `getOrderHeadersForAccounts` read checkout already makes; logins with an expired session were skipped): 3 orders in 30 days, all from #337 on Sep 27. The two seller split-offs ($99.66, $86.40) are DELIVERED. **The original draft id, which was the main order, now shows CANCELLED with 0 lines and $0. EnPlace shows #337 as submitted, $358.67.** See open items.
- **Performance:** all four logins have no open draft; nothing to read.

## Specs

- New: `spec/services/scrapers/sysco_checkout_checks_spec.rb`, `what_chefs_want_checkout_checks_spec.rb`, `performance_checkout_checks_spec.rb`.
- Changed: `order_placement_service_spec.rb` (per-line wording); `performance_ordering_spec.rb` (a refused delete now stops the order; add-to-cart stubs read the draft); WCW API doubles answer `last_error`.
- 40 of the 73 new or changed examples fail on the 3.3 commit (`a7a5252`). The rest pin behavior that must not change.
- Full suite: 1,943 examples, 0 failures (run against the branch's own test database).

## Open items

- **Sysco order #337:** Sysco lists the main order as CANCELLED, 0 lines. EnPlace says submitted, $358.67. Was it cancelled at Sysco after placing? Needs Carmin. Nothing changed here.
- **Sysco split orders** are still not recorded. Marketplace and Specialty items have been kept off Sysco orders since Sep 27, so splits shouldn't happen. If one does, the line-count check makes the order unconfirmed (email) instead of silently short.
- **Sysco `clear_cart`** without a tracked draft deletes every OPEN web draft on the account. This could include a chef's own draft on Sysco's site. Pre-existing, not changed.
- **WCW refusal after a retry:** the submit sends `duplicateIsOk: false`. That should make WCW refuse a duplicate, but this is unverified.
- **Messages** like "Order failed: submitOrderV2 failed: …" are rewritten in Phase 5.
