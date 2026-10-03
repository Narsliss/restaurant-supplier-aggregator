# Fix: made-up confirmation numbers (CW, PPO) and PPO's ignored delivery date

**Date:** 2026-10-03 · **Status:** built, specs green, live-probed (PPO), not yet deployed · **Order placement:** TOUCHED — CW and PPO `checkout` submit-result handling, PPO `add_to_cart` delivery date

## How this was found

Diagnosing order #386 (Chef's Warehouse, Skyllar, Oct 1). That order itself was **not** placed. It failed twice:
1. Juice Lemon Real wasn't in her CW order guide and was auto-removed, which put the order under CW's $400 minimum.
2. After she raised the honey quantity, CW silently dropped the honey at its price refresh. The existing guard correctly refused to place a partial order.

She then tapped Retry, which only resets the order to pending and erases the error, and then Cancel. The chef-facing gaps (no failure alert, Retry wiping the reason) are **not** in this change; see Open items.

The same Submit All placed #387 at PPO. Its worker log showed PPO rejecting our "set delivery date" call, which led to the bugs below.

## Bug 1: Chef's Warehouse confirmation numbers were made up

`checkout` read `result['orderNumber']`, which CW always returns as `nil`. The real number is nested:

```
{"confirmedOrders"=>[{"orderNumber"=>"TCW9912239489", ...}], "orderNumber"=>nil, "success"=>true, ...}   # order #331, Sep 27
```

So we filled in `"API-<timestamp>"`. **20 of 22 live CW orders** (Mar 24 – Sep 27) carry these made-up numbers. The orders were real and delivered; only the number shown was wrong.

The real danger is that a **rejected** submit (`nil`, `success: false`, or a timeout) produced the same made-up number and was recorded as `submitted`. We found no evidence this has happened, but nothing would have shown it if it had.

**Fix** (`chefs_warehouse_scraper.rb`):
- Read `confirmedOrders[].orderNumber`, and require `success == true`.
- With no number, decide without ever resubmitting:
  - `success: false` → fail with CW's reason ("Nothing was placed").
  - Items still in the CW cart → fail ("safe to try again").
  - Otherwise → `OrderUnconfirmedError`.

## Bug 2: PPO made up confirmations the same way

`"PPO-<timestamp>"` when `submitOrder` returned nothing. Since the PPO API client (Mar 23) every live PPO order has a real uuid. Only #39 (Mar 10, old browser version) has a made-up number, and #45 has the word "Item".

**Fix:** PPO's uuid is the only confirmation accepted. With no order back (or on a timeout), look the order up by uuid:
- `placed_at` set → placed.
- Still `DRAFT`/`IN_REVIEW` → fail ("Nothing was placed").
- Otherwise → `OrderUnconfirmedError`.

The order-history query the old code would have used (`searchOrders`) **no longer exists on PPO**, so a new `OrderStatus` query (`orders(where: {uuid})`) replaces it.

## Bug 3: PPO ignored the chef's delivery date

PPO changed its schema: `NewOrder_UpdateFulfillment` declared `$unplacedOrderStatuses: [order_status_enum!]`, but PPO now expects `[String!]`. Every date update was rejected, and `graphql` returned `nil`, which the caller ignored.

`clear_cart` empties PPO's single draft but keeps it, along with its date. So whenever a draft already existed, the order went out on **the draft's old date**. A fresh draft gets the right date from `createOrder`, which is why no wrong-date delivery has been seen (every live PPO order's date looks plausible).

**Fix:**
- Declare `[String!]`.
- Read back `returning[0].restaurant_desired_delivery_time` and raise `DeliveryUnavailableError` unless it is the chef's day. Hasura returns `returning: []` with no error when nothing matches, so "not nil" isn't enough.
- Re-check the draft's date right before submit (dry runs too).
- Send Eastern midnight via `America/New_York`. The old fixed `T04:00:00Z` is 11 PM the previous day once DST ends (Nov 1).

## Bug 4: CW dropped every item not in the chef's order guide

This is the root cause of #386's first failure. Since the CW API rewrite (`1623eff`, Mar 23), `add_to_cart` copied each cart line's metadata from the chef's CW **order guide**. Anything else was skipped as "Not in order guide", and `handle_skipped_cart_items` deleted it and placed the rest. The old browser version opened `/products/<sku>/` and could add anything CW sells.

Prod (`OrderValidation items_removed`): **9 items across 6 CW orders** since June. 5 of those orders were placed without the items:

| Order | Items dropped |
|---|---|
| #122 | trash liners, peeled garlic |
| #235 | trash liners |
| #288 | truffle oil |
| #305 | capicola, trash liners |
| #331 | freezer bags, blended oil |

#386 is the sixth.

**Live evidence (Oct 3, approved by Carmin):**
- **Read-only price check:** 8 of the 9 SKUs price under the derived code `JDE_{sku}-800001` (unrestricted). RWP1178B returned no price, probably another business unit.
- **Cart test:** on Skyllar's empty cart, `cart/add` with `JDE_QG80027A-800001` and default metadata gave `success: true`, and the cart showed 1 case at $45.40. The cart was then deleted and verified empty.

**Business units:** a read-only catalog walk (Oct 3) found 3,370 products in BU 800001 and **2,179 (39%) in BU 133002**, including Baking & Pastry (1,355) and Supplies (567). The cart code is `JDE_<sku>-<BU>`. RWP1178B prices only under `-133002` ($92.34). Cart test on Skyllar's empty cart: `JDE_RWP1178B-133002` with BU 133002 and vendor nil was accepted, and the cart was deleted after.

**Fix:**
- **Off-guide items:** `resolve_business_units` prices `-800001` and `-133002` in one `fetch_prices` call and uses the code CW prices (unrestricted). The line gets default metadata (stocking type `P`, vendor nil).
- **CW won't price it:** the item is reported failed with the reason "Chef's Warehouse has no price for this item on your account", which stops the order (Change 5).
- **The lookup itself errors:** the reason says "try again" instead.
- **Guide items:** unchanged.
- **CW drops a line anyway:** `verify_cart_matches!` or the price-refresh re-check stops the order and names it.

## Change 5: an item the supplier won't take stops the whole order (all suppliers)

**Before:** `OrderPlacementService#handle_skipped_cart_items` deleted every line that `add_to_cart` reported as failed, then **placed the rest**. The chef only saw a yellow banner afterwards. `verify_cart_matches!` ran after the deletion, so it never caught these.

**Decision (Carmin, Oct 3):** stop the whole order.

**Now:** `raise_for_items_not_added!` raises `ItemUnavailableError`, which `handle_item_unavailable_error` handles:
- the order goes to `status: failed`
- every line is kept, and the refused ones are marked `failed` with the reason
- nothing is submitted
- `error_message` reads: "Not placed. <Supplier> couldn't take N item(s): Name — reason; …. Remove or change it and resubmit."

Two more fixes in the same change:
- **Reason key:** Performance reports the reason under `:reason`, not `:error`, so its reasons were lost. Both keys are now read.
- **Stock flag:** `stock_related_error?('')` used to return **true**, so any failure with no reason (every Performance failure, including transient 5xx/auth errors) marked the product out of stock. Future orders then silently removed it at validation. A blank reason is now not a stock signal.

The other-supplier audit (Oct 3) shows why this applies to everyone:

| Supplier | Why an item can fail to be added |
|---|---|
| PPO | Lookup only searches the first 5,000 catalog items |
| Performance | Any per-item `ApiError` drops the item |
| WCW | One order guide, then a fuzzy search fallback |
| Sysco | Our own "unlisted" guess |

These lookup limits are still open. They now **stop** the order instead of shortening it.

## Change 6: our stock cache no longer deletes lines (supplier decides)

`OrderValidationService#validate_item_availability` deleted every line whose `supplier_product.in_stock` was false, before the supplier was asked, and placed the rest. If every line was cached OOS, it failed the order. That cache comes from import miss-tracking and the discontinue job, and until Change 5 also from failed add-to-cart calls with a blank reason, so it could be stale or poisoned.

**Decision (Carmin, Oct 3):** let the supplier decide. The method is removed. A supplier refusal at add-to-cart now stops the order with the reason (Change 5).

## New outcome: unconfirmed → `pending_manual`

`OrderUnconfirmedError` (BaseScraper) maps to `status: pending_manual` with an explanatory `error_message` (`OrderPlacementService#handle_unconfirmed_submit`). `pending_manual` is not `retryable?`, so the chef can't place a duplicate with one tap. They're told to check the supplier first.

## Live evidence (Oct 3, PPO, prod session for Skyllar's login, approved by Carmin)

| Probe | Result |
|---|---|
| Old fulfillment query, made-up uuid | `validation-failed … declared as '[order_status_enum!]', but used where '[String!]' is expected` |
| New query, made-up uuid | `{"update_orders":{"returning":[]}}` (accepted, matched nothing) |
| New query on the real draft, **same** date (no-op) | Echoed `2026-10-05T04:00:00+00:00`; draft unchanged |
| `searchOrders` | `field 'searchOrders' not found` |
| `OrderStatus` lookup | #387 → `DELIVERED`, `placed_at` set · draft → `DRAFT`, `placed_at: nil` · unknown → `[]` |

No order was placed and no cart was changed. Dev PPO sessions had all expired (30-day Cognito cap), so this could not be done in dev.

## What did NOT work / was ruled out

- Dev dry run for PPO: every dev PPO credential's session expired, and re-login needs a 2FA code from the chef.
- A dev dry run for CW wouldn't exercise this change: the dry-run branch returns before submit. The CW success shape is taken from #331's real response in the worker logs.
- Railway log search only covers the current deployment by default. Older logs need the deployment id (`railway logs <id>`).

## Specs

- `spec/services/scrapers/premiere_produce_one_checkout_spec.rb` (new): date fail-closed (nil, empty `returning`, wrong day), DST, pre-submit re-check incl. dry run, no invented confirmation, status-lookup outcomes. 10 of 13 original examples fail against the old code.
- `spec/services/scrapers/chefs_warehouse_scraper_spec.rb`: real `cart/submit` shape (the old stub `{orderNumber: 'TCW1'}` encoded the wrong assumption), split orders, `success: false`, nil + items still in cart, timeout + empty cart.
- `spec/services/orders/order_placement_service_spec.rb`: `OrderUnconfirmedError` → `pending_manual`, not retryable.

## Open items (not in this change)

- **Chef-facing failure alerts.** A failed or needs-action order sends nothing (`PlaceOrderJob#handle_failure` only logs); owners are emailed only on success. This is the #386 "never-event" ask.
- **Retry wipes the reason** (`OrdersController#retry_order` clears `error_message`). After #386's second failure, the page showed a green Submit and a stale lemon-juice banner.
- `PreOrderValidationService#validate_cached_stock_for_item` still **fails** an order (visibly) on our cached `out_of_stock?`/`discontinued?` flags for scrapers without `check_stock`. It is not silent, but it is the same "cache decides" pattern.
- **Other-supplier lookup limits:** PPO 5,000 catalog cap, WCW single guide + fuzzy search, Performance search, Sysco "unlisted". US Foods never reports a drop and doesn't re-read its cart.
- **Audit (Oct 3) found the same unchecked-date pattern elsewhere:**
  - CW `set_delivery_date` result is ignored.
  - US Foods masks a failed date PUT.
  - WCW sets the date only at draft creation, then overwrites `order.delivery_date` with whatever comes back.
  - Not verified live yet.
- PPO has no `verify_cart_matches!`, `clear_cart` swallows errors, and `checkout` takes `.first` draft.
- The 20 historical CW orders could be backfilled with real numbers from CW order history (prod data write; needs approval).
- `pending_manual` UI still labels the reason "Order failed"; wording should say "check the supplier".
