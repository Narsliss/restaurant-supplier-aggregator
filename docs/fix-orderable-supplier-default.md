# Fix: order-builder default and routing fallback ignore supplier connections

**Date:** 2026-09-25 · **Area:** ordering (routing only, no placement or scraper code) · **Status:** built, full suite green, not yet deployed

## What was wrong

A matched-list row can include a supplier that the chef building the order has no login for. This happens when another user's order guide is mapped to the same location. For example, on alfios list 8 only user 11 holds Performance and Sysco credentials, but every chef at that location sees rows that contain Performance and Sysco items.

`ProductMatch#cheapest_supplier` ranked every supplier on the row. It ignored whether the person ordering could actually place with that supplier. This caused two problems:

1. **Builder default (visible glitch).** The builder shows only the chef's connected suppliers plus email suppliers. When a hidden supplier was the cheapest, the pre-selected cell pointed at a supplier with no column on the page.
2. **Server routing fallback (latent bug).** `Orders::AggregatedListOrderService` uses `pm.cheapest_supplier` to route a line when no supplier is chosen. That fallback could send the line to the hidden supplier. `OrderPlacementService` places with the ORDERING user's own active credential, so that order could only fail. The current screens always send an explicit supplier in the nested `quantities[match][supplier]` params, so this path is reached only by the older flat param shape (saved carts, older clients). No production order has ever failed with a missing-credential error, but nothing prevented one.

## What changed

- `ProductMatch#cheapest_supplier(among: nil)` takes an optional list of supplier ids and ranks only within it. With no argument it returns the market-wide cheapest, memoized as before, so reports and the matching modal behave exactly as they did.
- `Orders::AggregatedListOrderService.orderable_supplier_ids(user)` returns the user's own **active** credentials plus the email suppliers. This is the same rule `OrderPlacementService#get_active_credential` applies. The service's fallback now calls `cheapest_supplier(among: orderable_supplier_ids)`. When no supplier on the row is orderable, the line is skipped and a warning is logged, so no order is created for it.
- `AggregatedListsController#order_builder` sets `@orderable_supplier_ids` to the visible suppliers intersected with that orderable set. The desktop card, desktop row, mobile card and mobile builder (`order_builder.html+mobile.erb`) all compute their default and BEST from it.

## Behaviour change to be aware of

The BEST pill in the builder now means "best among the suppliers you can order from". Before, when a hidden supplier was cheapest, no BEST pill appeared at all because it pointed at a column that wasn't shown. Now the cheapest visible supplier gets the pill. The list page and the matching modal still show market-wide BEST, since that screen is about comparison, not ordering.

## What was considered and not done

- **An explicit supplier choice for an unconnected supplier is not rerouted.** If a request names such a supplier, it still creates the order, and placement fails loudly with "No active credentials". Quietly moving a chef's explicit choice to a different supplier would be worse than a visible failure.
- **Managers:** `scoped_credentials` shows a manager every credential at their location, including other users' credentials. So a manager can see a supplier column they cannot place with. The default no longer lands there because of the intersection, but a manager can still pick that column by hand. This existing discrepancy is left as is and flagged as an open item.

## Tests

- `spec/requests/order_builder_orderable_default_spec.rb` (new) covers these cases. The cheapest supplier on the row belongs to a colleague, and the first cell in alphabetical order is not the cheapest orderable one.
  - The desktop orange ring goes to the cheapest orderable supplier.
  - The mobile `data-cheapest-supplier-id` points at that same supplier.
  - A submit with no supplier chosen routes there.
  - `among:` semantics (`nil`, a subset, and an empty list).
- The `routing without a connection` block in `spec/services/orders/aggregated_list_order_service_spec.rb` covers:
  - no credential;
  - a credential that is on hold;
  - another user's credential;
  - no orderable supplier at all, which creates no order;
  - an email supplier with no credential, which is orderable.
- Existing service specs now give their users active credentials. They failed without them, which confirms the gate is live.

## Open items

- The manager column and placement mismatch described above.
