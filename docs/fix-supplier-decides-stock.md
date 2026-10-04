# Pre-order validation: the supplier decides stock, not our cache

**Date:** 2026-10-03 · **Status:** built, full suite green (1,739 examples), not yet deployed · **Order placement:** TOUCHED, pre-validation only; the cart and submit steps are unchanged.

## Problem

`PreOrderValidationService#validate_stock_availability!` runs on every order (`PlaceOrderJob` never skips pre-validation). It tries `scraper.check_stock`, but **no scraper implements it**, so the NoMethodError dropped into `validate_cached_stock_for_item`. Any line our catalog flags `out_of_stock?` or `discontinued?` failed the **whole order** before the supplier was asked.

Those flags go stale:
- import miss-tracking sets `in_stock = false` and reinstating never resets it
- another restaurant's guide sync or failed add writes the shared `supplier_products` row
- for off-guide items only a guide sync ever sets `in_stock` back to true

Earlier today, Carmin decided the supplier decides (Change 6 in `fix-order-confirmation-and-ppo-delivery-date.md` removed the same pattern from `OrderValidationService`).

**Prod (Oct 3):** of 2,761 items on lists or ordered in the last 60 days, **111** are cached out-of-stock and **90** cached discontinued (84 at US Foods). Any order containing one of them failed pre-validation.

## The catch

Letting the supplier decide is only safe where we **confirm every line is on the supplier's cart before submitting**:
- CW, WCW and Performance have `verify_cart_matches!`.
- Sysco checks each SKU is on the order after `updateOrderV2`, and a missing one stops the order.
- **US Foods and PPO have no line check yet.** If they quietly drop a discontinued line, the order would ship short.

## Fix

- **`BaseScraper#confirms_lines_before_submit?`** is true when the scraper defines `verify_cart_matches!`; Sysco overrides it to true.
- **`validate_stock_availability!`:**
  - **Live `check_stock` available** (none today): use it. If it errors, fall back to the cache only for suppliers that don't confirm lines.
  - **No live check, and the supplier confirms lines** (CW, WCW, Performance, Sysco): skip the stock step. A refusal at add-to-cart stops the order and names the item.
  - **No live check, and the supplier doesn't confirm lines** (US Foods, PPO): keep the cached check as before, until they get a line check.

## Specs

- `pre_order_validation_service_spec.rb`:
  - cached OOS or discontinued doesn't block for a line-confirming supplier
  - cached OOS still blocks for one that doesn't confirm lines
  - a live-check error doesn't fall back to the cache for a confirming supplier
- `confirms_lines_before_submit_spec.rb`: CW, WCW, Performance, Sysco true; US Foods, PPO false.

## Open

- A US Foods / PPO line check would let them drop the cached check too. US Foods also hides a failed cart PUT behind a local copy of the order (`us_foods_api.rb:508`).
- The stale cached flags still affect the **UI**: "Out of stock" labels, exclusion from cheapest, suggestions. Reinstating an item should reset `in_stock`.
- `supplier_product_for` maps a line through its canonical Product to the *first* supplier product for that supplier, so it can be a sibling SKU. That no longer matters for stock at line-confirming suppliers, but the Performance minimum check in pre-validation still sums sibling prices.
