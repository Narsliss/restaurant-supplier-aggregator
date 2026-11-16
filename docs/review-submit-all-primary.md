# Review page: Submit All is the primary action

**Status:** built on branch `review-submit-all-primary` (Nov 15 2026), not merged or deployed.
**Files:** `app/views/orders/review.html.erb`, `app/views/orders/_submit_all_button.html.erb` (new),
`app/javascript/controllers/order_review_controller.js`, `spec/requests/review_submit_all_primary_spec.rb` (new).

## Why

Thursday Nov 12 2026, a D'oro chef reported that orders "would only go into draft and not
actually order", mostly at Chef's Warehouse. Railway logs for that day show what happened
(all times ET):

| Time | What the chef did | Result |
|---|---|---|
| 3:18:21 | Create Cart from aggregated list 15 | Drafts #587 CW $1,772.83, #588 PPO $565.65, #589 USF $466.22 |
| 3:18:46 | Pressed the orange **Submit Order on the US Foods card** | `submit_batch` got `order_ids: ["589"]`; only USF was placed, then the app redirected to `/orders/589` |
| 3:19–3:25 | Opened #588 and #587 repeatedly | A draft's page has no status badge and no Submit, only Reorder |
| 3:25 / 3:28 | Reorder → set date → submit | #590 PPO and #591 CW placed (TCW10505671204) |

Nothing failed and nothing was ordered twice. Supplier connections, including US Foods'
Microsoft (Azure B2C) sign-in, were healthy all day despite the Microsoft 365 outage. The cause was
the review page: four identical orange buttons, with the one that orders everything at the
bottom of the page.

Carmin, Nov 15: "Ideally the primary action we want chefs to press [is] the submit all button
rather than the individual buttons", plus a dialog that warns before ordering from only one
supplier when there are several.

## What changed

1. **Submit All is the one orange button**, rendered at the top (beside "Review Orders") and the
   bottom (larger) of the page, from one partial so both copies stay identical.
2. **Per-card buttons are quiet outlines** labelled "Submit only <supplier>". `SUBMIT_STYLES` in the
   controller owns both looks; the four duplicated class-toggling blocks are gone.
3. **Confirm before a single-supplier submit.** With other orders on the page, "Submit only
   this" opens a dialog: "Only order from US Foods?", the other orders and their totals, then
   **Submit All Orders** (mirrors the real button's label, e.g. "Submit 2 of 3 Orders") /
   **Only US Foods** / Cancel. If Submit All is unavailable (another order still checking
   prices, under its minimum, or missing a date) the dialog says so and offers only "Only
   US Foods" and Cancel. Escape and a click outside close it. With one order on the page there is no dialog.
4. **Submit All no longer greys out after quantity edits.** `_recalculateAll` disabled it unless
   EVERY order was ready, while `_updateSubmitStates` (page load, polling) offered
   "Submit 2 of 3". After any stepper tap the chef was left with only the per-card buttons.
   `_recalculateAll` now hands button state to `_updateSubmitStates`.
5. **Ordering impact: Submit All posts only the ready orders.** It used to post every order with
   credentials (`all_credentialed_ids`), so "Submit 2 of 3" sent 3. The unready one, if its
   status was `draft`/`pending`/`price_changed` (e.g. under its minimum), was placed and then
   rejected by validation, showing as a failed order. The partial now renders only ready ids,
   and `_setReadyOrderIds` rewrites the form's `order_ids[]` as readiness changes on the page.
   "Ready" uses the same rule the page already shows: credentials, minimum, case minimum,
   delivery date, verified, no blocking out-of-stock item.

6. **Every submit button waits for every price check.** While any order in the batch
   is `pending` or `verifying`, Submit All reads "Checking prices…" and every card's
   button reads "Waiting for prices…", all disabled. Carmin, Nov 15: "I don't want an
   impatient chef to click Order CW while Sysco is still verifying because it seems
   faster." On Nov 12, CW finished checking 8 seconds after the chef sent US Foods
   alone. `failed` and `skipped` count as finished, so one expired supplier login can't
   lock the page. Once all checks are done, Submit All covers every ready order
   ("Submit 2 of 3" when one has a problem the card names), and "Submit only <supplier>"
   still goes through the confirm dialog. The rule lives in `_updateSubmitStates`
   (`CHECKING_STATUSES`) and in the server render (`Order::CHECKING_VERIFICATION_STATUSES`).

   Considered and not chosen: blocking Submit All until every problem (minimum,
   date, out of stock) is fixed. Those don't clear on their own and a chef may
   mean to leave a supplier out; the label and the card say what's missing.

## Not changed

- `submit_batch` (server) is untouched. It still re-checks status, dates, deliverable days and
  credentials, and the order-placement path still enforces minimums.
- With JavaScript off, Submit All posts the ids that were ready when the page rendered (no
  date check at render; the server's date check still redirects with a message).
- The draft order page (`orders/show`) still has no "Draft" badge and no way to submit,
  only Reorder. This is the second half of the Nov 12 confusion and is a separate follow-up.
- After a single-supplier submit the app still redirects to that order's page. With the
  dialog in front of that path, the redirect is a conscious choice.

## Tests

`spec/requests/review_submit_all_primary_spec.rb`: while one order is still checking, Submit
All ("Checking prices…") and every card's button ("Waiting for prices…") are disabled, even
for the ready order; with checks done and one order failed, Submit All renders twice, reads
"Submit 1 of 2 Orders" and posts only the ready id (fails on the old code, which posted both);
per-card buttons are outlined "Submit only <supplier>" forms wired to `interceptSingleSubmit`; the
dialog markup is present; all-ready posts both. The JavaScript (dialog, live unlock when the
last check finishes, quantity edits) was checked by hand in the dev server (no JS test harness
in this repo), with every Solid Queue queue paused and no Sysco/Performance orders in the
test cart so nothing could contact a supplier.
