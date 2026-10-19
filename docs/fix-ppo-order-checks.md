# Premiere Produce order placement checks + split orders (plan Phase 2)

**Date:** 2026-10-19 · **Status:** built, NOT committed or pushed (Carmin: ship all phases together) · **Order placement:** TOUCHED (PPO add-to-cart, clear, a new line check, checkout; post-submit split reading; OrderPlacementService records supplier changes after a placed order). Every pre-submit change adds a stop. Post-submit additions never fail a placed order. · Plan: `docs/plan-out-of-stock-all-suppliers.md`.

## Why

- **It could ship short silently** (checkout audit A7/A8/A13 in `fix-cw-out-of-stock-message.md`). PPO had no line check. Specifically:
  - the `updateCart` reply was only checked for presence;
  - a rejected update reached the chef as "SKU Limes — API rejected", with the item NAME in the SKU field, so no line could be flagged;
  - `clear_cart` swallowed every error;
  - checkout submitted "the first open order";
  - the total added one price per line, ignoring quantity;
  - a failed availability read marked every item "in stock".
- **Found today (order 484, D'oro, placed Oct 19 for Tue Oct 20):** PPO **split the order into four** with different delivery days. EnPlace showed one order with all 12 items arriving Tuesday:
  - prosciutto + smoked mozzarella → **Wed Oct 21**
  - wagyu patties ×4 → **Thu Oct 22**
  - beef bone marrow → **Wed Oct 28**

  The submit reply carries `split_order_id_list`, and we never read it. Nobody was told. (Read-only queries confirmed it.) Sysco does the same with third-party items (memory, order #337).

## What changed

**Before submit (fail closed)**
- **New read-only query `ORDER_LINES_QUERY` / `PremiereProduceOneApi#order_lines`:** one order with its lines and quantities. Verified live on order 484; `order_item_prices` is one object per line. The open-orders query has no quantities.
- **`add_to_cart`:**
  - Remembers the exact draft (`@order_uuid`).
  - A failed catalog read stops with "Couldn't load Premiere Produce's catalog" (it used to mark every item "Not found in catalog").
  - A rejected cart update stops with **PPO's own error text** (`graphql` now keeps `last_error`).
  - Any of our lines missing from the `updateCart` reply is named right away ("Premiere Produce didn't add it to the cart"), the draft is emptied, and the delivery date isn't set.
- **`verify_cart_matches!` (new):**
  - Re-reads OUR draft with quantities and compares every line, ignoring leading zeros ("01298" = "1298").
  - Missing, extra or changed quantity → empty the draft, then `CartMismatchError` (missing lines carry our SKU, so OrderPlacementService names the item).
  - A draft that can't be read, or isn't DRAFT/IN_REVIEW, stops the order.
  - PPO now confirms its lines, so our cached "out" flag no longer gates PPO orders at pre-validation. PPO has 0 such flags and reports no outs, so nothing changes in practice.
- **`clear_cart`:** fails closed. A cart it can't read, or lines left after the clear, stop the order.
- **`checkout`:** submits OUR draft (`@order_uuid`), not the first open one. The total = price × quantity from the checked draft (2 cases at $12.50 used to record $12.50).

**After submit (best effort, never fails the placed order)**
- **Splits:** `ppo_order_changes` reads the placed order and every `split_order_id_list` order. It returns, in the `supplier_exceptions` shape:
  - **`delivery_changed`** for each of our lines on a different day than requested ("Arrives Wed Oct 28 — Premiere Produce put it on a separate order");
  - **`removed`** for a line on none of the placed orders;
  - nothing at all when any order can't be read (no claims on a guess) or when submit gave no answer.
- **`OrderPlacementService#record_supplier_changes`** saves them on the order and enqueues `OrderMailer.supplier_changed_order` (chef + owners), per the alerting rule for placed-then-inconsistent orders. It's isolated in a rescue, so the order stays submitted whatever happens.
- **Email** (`supplier_changed_order`): when every change is "arrives later", the subject reads "N items arrive on a later day" and the body says "will deliver these items on a later day … plan around them", with the arrival date per item. The old "can't send everything / get these elsewhere" copy remains for shorts. The label is "Arrives later".
- **The mobile order page now shows supplier changes** (`orders/_exception_alert`). Before, only desktop did, so the US Foods short-ship alerts never showed on phones either.

**Morning data**
- PPO availability: `nil` (unknown) when the availability list failed or has no entry for a pack; only `OUT_OF_STOCK` is out (`ppo_in_stock`).
- `ImportSupplierListsService#upsert_item`: nil keeps the existing value (new items default to in stock). Every other supplier sends true/false there, so only PPO's new nil is affected.
- PPO reads use the DST-safe `ppo_delivery_time` instead of a fixed `04:00Z`, which would be 11 PM the day before from Nov 1.

## Specs

- **`spec/services/scrapers/premiere_produce_one_ordering_spec.rb` (17):**
  - rejected update shows PPO's reason; dropped line named, emptied, no date set; catalog failure;
  - clear fails closed ×2, plus a passing clear;
  - line check: pass with leading zeros, missing (our SKU), quantity, extra, unreadable/non-draft, confirms lines;
  - checkout: our draft with price × quantity; order-484 split → `delivery_changed`; `removed`; unreadable split → nothing claimed;
  - availability nil/out/special.
- **`import_supplier_lists_service_spec.rb` (+2):** nil keeps an "out"; a new item with nil stock is in.
- **`order_placement_service_spec.rb` (+2):** changes recorded and emailed; recording failure keeps the order submitted.
- **`spec/mailers/order_mailer_supplier_changed_spec.rb` (2)** and **`spec/requests/order_supplier_changes_mobile_spec.rb` (1).**
- **Existing specs updated:**
  - `premiere_produce_one_checkout_spec.rb`: the `updateCart` stub now carries the real reply's lines;
  - `confirms_lines_before_submit_spec.rb`: PPO → true.
- **20 of the new examples fail on the old code.**

## What did not work / not done

- **`OrderSummary_ValidateOrder` is not used,** although the plan suggested it. It's a mutation whose side effects on the draft are unknown, and the read-only `order_lines` query gives the same lines.
- **Our `get_order_history` query is broken.** PPO answers "field 'searchOrders' not found". It isn't used by placement; noted for later.
- **Not caught BEFORE placing:** a split onto later days. PPO marks 21 items SPECIAL_ORDER; whether those are the ones it moves to later days is unconfirmed. A pre-submit warning would need that link (Phase 3.3 / 5).
- **Order 484 itself was not changed.** Carmin was told on Oct 19 so D'oro knows four items come Oct 21, 22 and 28.
