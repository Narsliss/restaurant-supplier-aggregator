# Fix: guide syncs touching other restaurants' lists ("stuck syncing")

**Date:** 2026-10-20 · **Status:** built and tested (full suite 2153/0), on branch `fix-stuck-syncing-lists`, not committed or pushed · **Order placement:** none. Guide sync only; it doesn't gate orders, matching or prices.

## What happened

A read-only production check on Oct 20 found **35 of Alfio's lists** stuck on "syncing" for days:

| Restaurant | Supplier | Lists | Marked "syncing" since |
|---|---|---|---|
| D'oro | Chef's Warehouse | 3 | Oct 17, 08:03 |
| Noche | US Foods | 17 | Oct 18, 08:03 |
| alfios | US Foods | 15 | Oct 18, 08:03 |

- **No job was running** (zero claimed jobs), so this was never a hung job or a memory leak.
- **`sync_status` only drives display:** the "Syncing" badge on the supplier lists page, and the admin Operations "stuck syncing" count. It doesn't gate orders, matching or prices.
- **The real effect:** those restaurants' guides hadn't refreshed since Oct 17–18. Their guide prices came from the 6 AM catalog copy instead of their own account, which is within the ~10% display tolerance, and checkout confirms the real price.

## Why

Alfio's has several logins per supplier:
- **Owners:** one owner login covers alfios and Noche, and the other covers D'oro.
- **Chefs:** each chef has a personal login, about 9 per supplier, kept for savings attribution.

The guide sync treated the whole organization as one restaurant in four places:

1. **Marking.** `ImportSupplierListsJob` set **every** list of that supplier in the organization to "syncing" when a sync started, but the sync only finished the lists its own login reached. The others stayed "syncing". Because the update skips lists already "syncing", their `updated_at` froze at the first mark.
2. **Skipping.** The 4-hour freshness skip was also organization-wide. If one restaurant's lists had synced recently, another restaurant's sync was skipped, and no log was written.
3. **Failing.** A crash marked every "syncing" list in the organization as failed.
4. **"No longer found."** `ImportSupplierListsService#mark_removed_lists` marked any list in the organization that this login didn't see as "List no longer found on supplier site". Only the multi-restaurant path limited it to one restaurant. So a chef's Sync at Noche could fail alfios' and D'oro's lists.

## The fix

- **The job** (`ImportSupplierListsJob#lists_this_login_syncs`): marking, the freshness skip and crash-failing cover only the lists this login's sync can reach. That's its own restaurant, or each restaurant matched on a multi-restaurant login.
- **The service:** `mark_removed_lists` judges only the restaurant being synced (`target_location_id`).

## Not changed, by decision

**The 8 AM job still syncs one login per supplier per organization,** and breaks the tie between Alfio's two owner logins arbitrarily. Carmin, Oct 20: it doesn't matter, because the target design (`prd-prices-and-guides-at-scale.md`) drops scheduled per-restaurant guide reads. So which restaurant's guide refreshes on a given day may vary until then.

## How the 35 labels clear

Each list clears the next time **its own restaurant's login** syncs it: the 8 AM job when it picks that login, or a Sync press on that restaurant's lists. No production data was edited by hand. Because the daily pick is arbitrary, a stuck label can last a few days. One Sync press per restaurant clears it immediately.

## Tests

`spec/jobs/import_supplier_lists_job_scoping_spec.rb`. Run against the old code, 5 of these 6 fail; the sixth is a control that should pass either way.
- One restaurant's sync leaves another's lists alone.
- Another restaurant's fresh lists don't skip this one.
- A login's own fresh lists still skip it (the control).
- A multi-restaurant login marks each of its restaurants, and only those.
- A crash fails only this login's lists.
- "No longer found" judges only the login's own restaurant.

`spec/jobs/import_supplier_lists_job_spec.rb`: the freshness-skip example now puts its fresh list at the login's own restaurant. It relied on the organization-wide skip.
