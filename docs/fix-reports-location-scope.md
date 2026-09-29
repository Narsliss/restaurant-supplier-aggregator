# Fix: Reports showed only the first restaurant

**Date:** 2026-09-29 · **Status:** built, full suite green, not yet deployed · **Order placement:** untouched

## What Carmin saw

Impersonating Alfio (owner of alfios, Noche and D'oro), the Reports page only ever showed alfios, whatever the navbar dropdown said. Noche read $0, although it had 17 submitted orders ($5,291.63) in the last 30 days against alfios' 14 ($7,634.46).

## Two causes

1. **Reports followed the navbar location switcher.** `ReportsController#base_orders` used `scoped_orders`. For an owner, that limits orders to `current_location` unless the session says "all". The switcher exists for ordering, where everything happens at one restaurant. A report compares restaurants: it has a by-restaurant breakdown and its own `location_id` filter. With one restaurant selected, the breakdown still listed every restaurant but showed $0 for all the others.
2. **While impersonating, the switcher itself was refused.** `ImpersonationGuard` blocks every non-GET request, and `POST /locations/switch` is a POST. The web logs for Sep 29 show both switches, to "all" at 2:58 PM ET and to Noche at 2:59 PM ET, halted by `block_writes_while_impersonating`. The dropdown makes its request in the background, so the "Read-only mode" message never appeared. The session kept its default: the owner's first restaurant.

## The fix

- **`ReportsController#report_orders`**: owners get all of the organization's orders, and managers get the orders at their assigned restaurants. The navbar location is ignored. The report's own `location_id` filter still narrows it to one restaurant.
- **`ImpersonationGuard`** allows `locations#switch`, which only changes the viewer's session. Every other write stays blocked.

Specs: `spec/requests/reports_location_scope_spec.rb` covers the report ignoring the navbar, the report's own filter, a manager's scope, the switcher while impersonating, and writes still blocked. The three that target the bugs fail without the fix.

## Not changed

Other pages keep following the navbar location on purpose (order builder, lists, purchasing).
