# Supplier minimums are per restaurant, not shared across EnPlace

**Date:** 2026-10-03 · **Status:** built, full suite green (1,756 examples), dev-checked, not yet deployed · **Order placement:** minimum lookups now use the order's location in two places that ignored it. No migration.

## Problem

`supplier_requirements` has no organization column. A row with `location_id: nil` is the **EnPlace-wide default shared by every restaurant**.

The settings page (Team & Organization → Supplier Requirements) showed it as an editable "Default" column, open to every member. Saving it:
- **rewrote the minimum for every restaurant on EnPlace**, in every organization;
- **deleted every restaurant's per-location minimums** for that supplier (`OrganizationsController#update_requirement`: `.where.not(location_id: nil).destroy_all` with no organization scope);
- **locked** every location's own box while a default existed. Defaults exist for CW, US Foods, PPO, WCW (order minimums) and Performance (case minimum), so per-location minimums couldn't even be set for them.

**Prod (Oct 3):** 6 shared rows, 12 per-location rows. Any chef in any organization could wipe the 12 or change the minimum for all.

**Why it matters:** a minimum set **too high** makes EnPlace **block** an order that the supplier would accept (it's blocking in `OrderValidationService` and on the review page). Minimums genuinely differ by account.

Carmin: per location; pre-populating everyone with a default is fine.

## Fix

- **`update_requirement`:** a blank `location_id` (the shared default) returns **403 unless super admin**. A super admin's change no longer deletes anyone's overrides. Members set their own organization's locations as before; another organization's location is not found.
- **`update_delivery_schedule`:** this also writes shared (`location: nil`) rows, so it is now super-admin only. It isn't linked from any page, and there are 0 such rows in prod.
- **Settings page:**
  - The "Default" column is now a read-only **"EnPlace default"**.
  - Every restaurant gets its own editable box, never locked, with the default as grey placeholder text.
  - A blank box uses the default; clearing a box reverts to it.
  - The grid script's lock logic was removed.
- **Location-aware lookups:** `OrderPlacementService#recheck_order_minimum_after_removals!` and `OrderItemsController` (the add/remove-item minimum JSON) now call `order_minimum(order.location)` like the review page does.

## Specs

`spec/requests/per_location_minimums_spec.rb`:
- a chef sets their own location
- a non-admin can't change the shared default (403, value unchanged)
- another restaurant's minimum survives any save
- another organization's location is untouchable
- clearing a box reverts to the default
- a super admin can change the default without touching overrides
- the page shows editable boxes with the default as placeholder and nothing locked

4 of the 7 fail on the old code.

## Not changed

The 6 existing shared defaults stay as the EnPlace-wide starting values. Super admins still edit them, though there's no page for it now; that's a console job.
