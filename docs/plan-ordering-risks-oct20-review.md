# Plan: an unanswered submit never says "safe to try again" (risk #4 from the Oct 20 out-of-stock review)

Status: **APPROVED by Carmin Oct 20 2026: narrow version only.** The three read-backs become "unconfirmed". Clear refusals keep Fix & Resubmit. Built: see `docs/fix-unanswered-submit-unconfirmed.md`.

The Oct 20 read-only review of the Oct 19 out-of-stock work found 7 ordering risks. #1 (a deploy mid-order causing a double order) shipped Oct 20 in db72f81. This plan covers **#4 only**.

The other open risks were discussed and **parked** (Carmin, Oct 20): their bugs have never hit a user, and their fixes touch paths that run far more often than the bugs do. What was learned about them is under "Parked" at the end.

**Volume** (read-only production check, Oct 20): 83 real orders in 120 days, about 5 a week, leaving out test orgs 6 and 11. 81 submitted, 2 Chef's Warehouse cancelled. None failed, none unconfirmed.

---

## The bug

Three suppliers make one read right after a submit they didn't answer. If the order still shows in the cart, they raise `NotPlacedError` "… Nothing was placed; it is safe to try again". `OrderPlacementService#handle_generic_error` treats `NotPlacedError` as "not placed" even after the submit went out, and writes `failed`, which gets a Fix & Resubmit button. A retry clears `submit_sent_at` and does a fresh clear, add and submit. If the first submit was still going through, the restaurant gets two orders.

| Supplier | Where | Exposed since | Why "still in the cart" doesn't prove "not placed" |
|---|---|---|---|
| US Foods | `us_foods_scraper.rb` `confirm_unacknowledged_submit!` | Oct 19 (0601646) | US Foods takes orders asynchronously (order 482 came back SUBMITTING). A read right after a timed-out submit can still show IN_PROGRESS. |
| Chef's Warehouse | `chefs_warehouse_scraper.rb` `confirm_unacknowledged_submit!` | Oct 3 (93a360b) | A timeout or error page at our end doesn't mean CW stopped processing. Its cart can still read full. |
| Premiere Produce | `premiere_produce_one_scraper.rb` `confirm_unacknowledged_submit!` | Oct 3 (93a360b) | Same: a DRAFT read straight after a timeout doesn't prove the submit was dropped. |

**Hit by a user?** Not visible, and it can't be ruled out: a retry reuses the order record and wipes the old message, so a double order looks like one normal "submitted" order. Zero of the 83 orders ended unconfirmed, which suggests unanswered submits are rare.

## The fix (narrow)

In each of the three `confirm_unacknowledged_submit!` methods, the "still in the cart / still a draft" branch raises `OrderUnconfirmedError` instead of `NotPlacedError`. The message says what we saw and tells the chef to check the supplier before reordering.

**Unchanged:**
- Clear refusals after the submit keep "not placed" and Fix & Resubmit: CW `success: false`, What Chefs Want, Performance, Sysco.
- `OrderPlacementService`, `PlaceOrderJob`, every view, and the other three suppliers.
- Everything before the submit goes out.

## Blast radius and risk

- **Code touched:** one `raise` and its message, in each of three methods.
- **When it runs:** all of these at once:
  - in production (dev dry-runs return before the submit);
  - our live submit request has already gone out;
  - the supplier's answer wasn't a confirmation (timeout, dropped connection, HTTP error, unreadable page);
  - the immediate read still shows the order in the cart.
- **What it can't touch:** building the cart, item refusals, minimums, delivery dates, confirmed orders (they never reach this method), dry runs, the other suppliers, and every screen.
- **Where it hands off:** an existing production path. `OrderUnconfirmedError` → `handle_unconfirmed_submit` → `pending_manual` (not retryable) → `PlaceOrderJob#alert_not_placed` (kind `unconfirmed`) → `OrderFailureAlertJob`, which always emails the chef and owner(s) for this kind. The same three methods already take this path when the cart reads empty, and Sysco, What Chefs Want and Performance take it for any unanswered submit.
- **What changes for a chef, in that rare moment:** "check US Foods before reordering" plus the email, instead of "safe to try again" plus Fix & Resubmit. If the supplier doesn't have it, she uses Reorder on desktop, or rebuilds it in the builder on her phone (mobile has no Reorder by design).
- **What could go wrong:**
  - A false alarm when the supplier really never got it: a look and some extra steps, never a wrong order.
  - A typo in the new lines would raise a different error at the same moment. `handle_generic_error` already treats any unexpected error after the submit as unconfirmed, so it lands in the same place.
- **Ship:** one push, which restarts web and worker. Push only while the production worker is idle. No migration, no data changes. Rollback is a revert and a push.

## Regression tests

- Update the specs that expect "safe to try again": `us_foods_ordering_spec.rb:204` and `:232`, `chefs_warehouse_scraper_spec.rb:526`, and the PPO equivalent. Each now expects `OrderUnconfirmedError` and a "check the supplier" message.
- Keep: CW `success: false` → still `NotPlacedError`. Placed read-backs still return the supplier's number.
- `OrderPlacementService`: a live submit that ends with the read-back's `OrderUnconfirmedError` → `pending_manual`, not retryable, `error_type: 'unconfirmed'`.
- A tripwire spec: the phrase "safe to try again" appears nowhere under `app/services/scrapers/`.
- Full suite on its own database (`DATABASE_URL=postgres:///restaurant_supplier_aggregator_test_oosrisks`).

---

## Parked (Carmin, Oct 20): not in this change

Re-verified in code on Oct 20. Kept here so nobody has to find them again.

- **#6, a failed edit on the order page, then Submit.** `order_edit_controller.js` only logs failed PATCH/DELETE to the console, and `flushBeforeSubmit` submits anyway. The desktop review page (`order_review_controller.js`) has the same console-only failures and doesn't wait for pending saves before `submit_batch`. A fix that only covers the order page is about 20 lines of JS. A server-side "what the screen showed" check was proposed and rejected as too wide (it touches every submit).
- **#2, the pre-order check sees no items.** `PreOrderValidationService#order_items` queries the database for an unsaved list (0 items, every order), and `supplier_product_for` caches by a nil id. No effect today. It only bites a Performance account with a minimum ("Current total: $0.00").
- **#3, CW count 0 means "out" for special-order items.** `stockingType` is parsed but never used. A fix needs a read-only look at CW's catalog first.
- **#5, an error page marks every line out.** The exposed path is Performance (each line's reason is `HTTP 503 …: <page text>`), not CW's cart call.
- **#7, `review_stock_warning_spec.rb:94` fails 00:00–00:10 ET.** Fix: pin that group's clock to noon ET.
- **Rejected for #4:** making clear refusals "check the supplier" too (it reaches all six suppliers), re-reading several times for proof, and matching a re-filed US Foods order by date + items.
