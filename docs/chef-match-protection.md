# Chef match protection: nothing silently deletes matching work

**Date:** 2026-09-25 · **Status:** built, full suite green (1,353 examples), not yet deployed · **Ordering code:** untouched

## Why

On Sep 15 2026 a routine guide refresh deleted supplier list items that chefs had matched and confirmed. The delete cascaded to their matched rows twice over: through `SupplierListItem has_many :product_match_items, dependent: :destroy`, and again through the database foreign key `ON DELETE CASCADE`. Confirmed rows were left empty, and nothing recorded what was lost. Eight alfios rows and three Noche rows could not be reconstructed. See `docs/fix-guide-sync-erasing-matches.md`.

The sync fix (`9e47d38`) closed that one path. Carmin's requirement goes further: chefs must not lose hours of work to issues like this. So the protection is now a rule the database enforces, not a list of allowed callers.

## The rule

1. **A supplier list item that any matched row uses cannot be deleted.** This holds whatever the row's status is, and whatever is doing the deleting: a sync, an import, a failed supplier login, or future code.
   - `SupplierListItem` → `has_many :product_match_items, dependent: :restrict_with_exception`
   - The foreign key `product_match_items → supplier_list_items` changed from `ON DELETE CASCADE` to `ON DELETE RESTRICT`, so even a raw SQL delete is refused.
2. **Removing a supplier connection is the one deliberate path.** It is Carmin's call: "they made a conscious decision here." Everything happens in `MatchedListSupplierRemoval`:
   - That supplier's items come out of the matched rows first; `SupplierCredential before_destroy` runs ahead of the lists' dependent destroy.
   - Any row left completely empty is deleted, unless a chef's order list or saved cart still points at it. Those rows stay, and the health check reports them.
   - Deleting a supplier (`Supplier before_destroy`) works the same way.
   - Deleting an organization clears its matched lists first, so its list items are free to go.
3. **A failed login removes nothing.** Credential status changes (hold, expired) never delete lists or items. This was already true; it is now covered by a test.
4. **Unchanged:** chef edits in the matching modal and cleanup merges remove match entries directly, not list items, so they work exactly as before.

## A record of every removal

Every `ProductMatchItem` destroy writes a `MatchItemRemoval` row: organization, list, row (name and status), supplier, list item, SKU, product, **cause** and **user**.
- The table has no foreign keys, so the record outlives what it describes.
- The cause comes from `MatchChange`, a `CurrentAttributes` label: `chef_edit`, `cleanup_merge`, `auto_merge`, `rematch_all`, `row_deleted`, `supplier_connection_removed`, `supplier_deleted` or `unspecified`.
- Deleting a whole organization is not recorded.
- The record is written in its own savepoint, so a failure to write it never undoes the chef's action.

## Daily health check

`MatchHealthCheckJob` runs every day at 11:00 UTC (7 AM Eastern), after the 8 AM UTC list sync.
- It stores a snapshot (`match_health_checks`) of visible rows that have no items, and of the order-list entries pointing at them.
- It emails the super admin whenever either set has grown since the previous snapshot. The email lists each new row with its last recorded removal cause.
- **The first production run will email the current baseline:** about 53 empty rows and 34 order-list entries on them.

## Tests

- `spec/models/chef_match_protection_spec.rb` (13 examples) covers:
  - an item a row uses can't be deleted, whether the row is confirmed or machine-matched;
  - the database refuses a raw delete;
  - a failed login removes nothing;
  - unused items still delete;
  - removing a connection takes out only that supplier, records who did it, and deletes emptied rows unless an order list points at them;
  - deleting a supplier and deleting an organization both work;
  - the `chef_edit` and `row_deleted` records.
- `spec/requests/match_item_removal_audit_spec.rb`: a chef choosing "No match" in the popup is recorded as `chef_edit`, with their user id.
- `spec/jobs/match_health_check_job_spec.rb` (4 examples): the first-check baseline, silence when nothing changed, only new rows reported (with their cause), and removed rows ignored.
- `spec/services/matched_list_cleanup_service_spec.rb`: merges are recorded as `cleanup_merge`.

## Open items

- About 53 empty rows remain from before this change: alfios 11, list 10 17, list 14 11, list 6 4, Noche 3, list 11 3. Their contents cannot be identified, and the health check's first email will list them.
- A manager can still see supplier columns for other users' connections in the builder. This predates this change and is logged in `docs/fix-orderable-supplier-default.md`.
