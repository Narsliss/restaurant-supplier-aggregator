# A chef always knows when an order didn't go through

**Date:** 2026-10-03 · **Status:** built, full suite green (1,697 examples), dev-verified on mobile, not yet deployed · **Order placement:** submission unchanged. The new code runs after a failure, plus one ordering fix in `OrdersController#submit` (see below).

## Why

On Oct 1, order #386 (Skyllar, Chef's Warehouse) failed twice. After the second failure she tapped "Retry Order". That reset the order **and erased the reason**. Her phone then showed a green Submit button, no explanation, and nothing marking the refused honey. She tapped Cancel and later said she got no warning.

Separately, a chef who taps Submit All and locks her phone hears nothing if an order fails. `PlaceOrderJob#handle_failure` only logged. Owners were emailed only on **success**.

That gap grew with [fix-order-confirmation-and-ppo-delivery-date.md](fix-order-confirmation-and-ppo-delivery-date.md). Problems that used to ship a short order now **stop** it, and a stopped order nobody sees means nothing arrives.

## Carmin's rules (Oct 3)

- **A failure the chef can fix in the app:** no email, but it must be impossible to miss in the app, especially on mobile.
- **A failure she didn't see, or one that looked placed and then turned out inconsistent:** email her **and** the owner(s). Email only, no SMS or push.
- **Dismissing** a failed order means "Don't place this order", which **cancels** it.
- **The fix screen** stays small: remove the item, or add items to reach the minimum. Moving an item to another supplier is later.

## What was built

### 1. Email for failures she didn't see (`OrderFailureAlertJob`)

- When placement ends **not placed** (`failed`, `pending_review`, `pending_manual`), `PlaceOrderJob` schedules the alert. It does this on both the result path and the exception path, and the hook swallows its own errors (see the PlaceOrderJob rescue hazard).
- **Two-minute window:** the email is sent only if the chef's own screen didn't render or poll the order in that time. The order page, batch progress page and both status endpoints record "seen". A locked phone pauses polling, so it counts as unseen.
  - Only **her** views count. An admin impersonating her doesn't count, and neither does the owner.
- **Always emailed, seen or not:**
  - **Unconfirmed submits** (`OrderUnconfirmedError` → `pending_manual`): the supplier may have the order, and she can't settle that in the app.
  - **Stuck orders:** `StuckOrderAlertJob` runs every 5 minutes (production `recurring.yml`) and finds orders still `processing` after 15 minutes. It sends an alert only; the status is left alone.
- **Recipients:** the ordering chef plus the org owners, de-duplicated. `OrderMailer#order_not_placed` shows a red headline, the reason, every item with refused ones flagged, and an "Open this order" button.
- **No migration:** the seen, latest-failure and sent markers live in `Rails.cache` (Solid Cache, Postgres) with a 3-day TTL. Any doubt (null store, eviction, cache error) means **send**: a duplicate is acceptable, a miss is not. Each attempt has a token, so a superseded attempt or a since-placed order doesn't email, and a double job run emails once.

### 2. The reason stays; "Retry" became "Fix & Resubmit"

- `retry_order` no longer clears `error_message`. It clears when she resubmits (`submit` and `submit_batch`).
- **`OrdersHelper#order_failure_notice`** labels the reason by status:

  | Status | Notice title |
  |---|---|
  | `failed` | "Order NOT placed" |
  | `pending_review` | "Order NOT placed: needs your review" |
  | `pending_manual` | "Check with the supplier before reordering" |
  | `pending` after Fix & Resubmit | "Your last attempt wasn't placed. Fix this, then resubmit" |

  Desktop and mobile both use it. A "Confirmed" box can no longer appear next to it.
- **`order_shortfall_without_failed`** adds a line like "Without Classic Honey you're **$71.26 under** the $400.00 minimum".
- **Mobile items:** a refused item gets a red border and "Not taken by <supplier>: <reason>", plus a **Remove** button while the order is editable. The page reloads after a removal (new `reloadOnRemove` value on `order-edit`).
- **Mobile quantity buttons were broken before this.** They called `incrementQuantity`/`decrementQuantity`, which don't exist on the controller. They're now wired to `incrementItem`/`decrementItem`, with `itemRow`, `quantityInput`, `lineTotal` and `orderTotalFooter` targets. Without the targets, any quantity change also disabled Submit, because the row count read as 0.
- **`OrdersController#submit` race:** it used to enqueue the job **before** setting `processing`, so a fast failure could be overwritten back to "Submitting…" with its reason erased. It now sets `processing` first, as `submit_batch` already did.

### 3. Red bar on every screen (`shared/_unplaced_orders_bar`)

- **Where:** mobile and desktop layouts, for top-level controllers only.
- **What it lists:** every order **this chef** placed that isn't placed (`Order.needing_chef_attention`): failed, needs review, needs manual check, fixed but not resubmitted, or processing for more than 15 minutes.
  - Delivery date today or later, or no date.
  - Updated in the last 14 days.
  - The order being viewed is skipped, since its page already shows the notice.
- **Each row:** supplier, date and a "Tap to fix" link, plus **"Don't place"** (two-tap confirm), which cancels the order. `can_cancel?` now includes `failed`. "Don't place" isn't offered for `pending_manual` or stuck orders, where the supplier may already have the order.

## Verified

- Specs:
  - `spec/jobs/order_failure_alert_job_spec.rb`: schedule timing, seen vs unseen, superseded, already placed, dedupe, unconfirmed always, null cache fails safe, chef-is-owner, stuck sweep.
  - `spec/jobs/place_order_job_spec.rb`: the alert hook, including that it can't change order state.
  - `spec/requests/orders_spec.rb`: who counts as "seen", including the impersonation case.
  - `spec/requests/order_failure_fix_flow_spec.rb`: #386's sequence on mobile, the bar, "Don't place", and the scope's edges.
- **Dev, mobile 375×812, test chef:** a dev order was staged as failed and restored afterwards. Checked:
  - the bar appears on Orders
  - the order page notice and shortfall
  - the refused item is marked
  - Fix & Resubmit keeps the reason
  - + and − update the line and subtotal and persist
  - Remove is shown
  - no new console errors

## Not done / open

- Moving a refused item to another supplier (Carmin: later).
- SMS or push (Carmin: not now).
- The mobile Submit button turns orange instead of green after a quantity change, because `_updateSubmitState` uses the desktop classes. Cosmetic.
- `PreOrderValidationService#validate_cached_stock_for_item` still fails orders on our cached stock flags (visibly), the same "cache decides" pattern removed elsewhere.
