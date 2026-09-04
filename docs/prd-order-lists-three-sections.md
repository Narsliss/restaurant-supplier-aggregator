# PRD: Order Lists page — three sections (My / Shared / Supplier)

**Date:** 2026-09-04
**Requested by:** Carmin
**Status:** Implemented, pending review

## What

The `/order_lists` page previously showed one flat grid of every list at the
current location. It now shows three sections:

1. **My Order Lists** — lists the signed-in user created. Always visible;
   shows a create prompt when empty.
2. **Shared Order Lists** — lists created by other people at the location.
   Hidden when empty. Cards show "by <creator name>".
3. **Supplier Order Lists** — lists seeded from supplier data
   (`order_lists.seed_supplier_id` present), e.g. "Recent US Foods Orders".
   Hidden when empty.

No visibility change: everything remains location-shared, exactly as before.
Favorites-first ordering carries into each section.

## Permission changes

- **Supplier lists are view/use-only for everyone.** No renaming, no item
  adds/removes/quantity edits, no favoriting — not even by the chef whose
  credential seeded them, and not by owners (any local edit would be
  overwritten by the mirror sync below). A "Duplicate" button on the card and
  on the show page makes an editable personal copy (the copy drops
  `seed_supplier_id`).
- **Owners may still delete any list, supplier lists included.** The
  tombstone (`OrderListSeedRecord`) keeps the daily sync from resurrecting a
  deleted seeded list; the explicit "Refresh Recent Orders" button can
  re-create it.
- **Other users delete/edit only their own lists** (unchanged for user
  lists).
- `OrderListItemsController` previously had **no permission guard at all** —
  any location member could add/edit/delete items on any list. It now
  enforces the same rule as the lists controller (`can_edit_order_list?`).
- `duplicate` is now open to any operator on any visible list (it used to be
  creator/owner only) and assigns the copy to the duplicating user, not the
  original creator.

Shared helpers live in `OrganizationAuthorization`:
`can_edit_order_list?(list)` / `can_delete_order_list?(list)`, also exposed
to views.

## Seeder change: additive top-up → true mirror

Carmin's requirement: "if they change the list on the supplier it should
update here at some frequency."

Previously:
- The daily 8 AM sync only ever **first-seeded** a location
  (`SeedOrderListsService#call` no-op'd when a seeded list existed).
- The "Refresh Recent Orders" button was **additive only** — never removed
  items — because chefs could edit seeded lists and we refused to clobber
  their curation.

Now that seeded lists are read-only, both paths **mirror** the supplier
source (`SeedOrderListsService#mirror_items`): items the feed dropped are
removed, new ones added, quantities and guide order tracked. Runs after
every list import, so the daily 8 AM sync keeps supplier lists current.
Safety: an empty feed never wipes the list (`no_seedable_items` skip — a
bad sync is likelier than a cleared account). The list description is also
rewritten on each mirror, which self-heals the old "edit freely, it's
yours" copy in prod.

## Known trade-off (flagged to Carmin pre-deploy)

Any **existing chef edits to seeded lists in prod** (items chefs added to or
pruned from "Recent … Orders" lists while they were editable) will be
overwritten by the first mirror sync after deploy. There is no reliable way
to distinguish chef edits from feed drift, so we did not attempt to
preserve them. Chefs who customized a seeded list should duplicate it.

## What did NOT work / dead ends

- Reusing the dormant `order_lists.visibility` column: Carmin confirmed
  sharing stays implicit (location-wide), so no private/shared toggle was
  built. The column remains unused.

## Files

- `app/controllers/order_lists_controller.rb` — section partition in
  `index`; `require_editable_list!` / `require_deletable_list!` replace
  `require_list_owner!`; duplicate assigns `for_user: current_user`.
- `app/controllers/order_list_items_controller.rb` — new guard.
- `app/controllers/concerns/organization_authorization.rb` — permission
  helpers.
- `app/models/order_list.rb` — `seed_supplier` association,
  `supplier_seeded?`, `supplier_seeded`/`user_created` scopes,
  `duplicate!(for_user:)`.
- `app/views/order_lists/index.html.erb` — three sections;
  `_order_list_card.html.erb` extracted.
- `app/views/order_lists/show.html.erb` — read-only banner + duplicate for
  seeded lists; shared `can_edit_order_list?`.
- `app/services/seed_order_lists_service.rb` — `mirror_items`, auto-mirror
  in `call`, new description copy.
- Specs: `spec/requests/order_lists_spec.rb` (sections + permissions),
  `spec/services/seed_order_lists_service_spec.rb` (mirror semantics).

## Open items

- Managers get no Duplicate button (they're not operators) — consistent
  with them being read-only, but worth revisiting if managers should build
  lists.
- Sysco has no seed source, so connected-Sysco locations show no supplier
  list for it (pre-existing; see prd/order-list seeding notes).
