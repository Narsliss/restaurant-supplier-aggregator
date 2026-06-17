# PRD: Matching Page Redesign & Canonical Items

- **Status:** Draft / awaiting approval to implement
- **Date:** 2026-06-17
- **Owner:** CJ Moutinho
- **Depends on:** PRD 1 — Product Image Thumbnails (`docs/prd_product_image_thumbnails.md`)
- **Related memory:** `reference_supplier_product_images.md`, ordering-safety notes

---

## 1. Summary

Restructure the matching page from an inline-editing surface into a **display-only** list, and move all per-row matching into a **modal** opened by clicking a row. The modal becomes the single editor for a match: it sets the **canonical name**, the **canonical image** (picked from the matched suppliers' thumbnails), and the supplier-item matches — and it shows the primary item's thumbnail plus each selected candidate's thumbnail as a visual match aid.

The **canonical image** (a `ProductMatch`-level, chef-chosen image) then displays on the product-match row, in **order lists**, and in the **cart/order**, so the chef recognizes the item regardless of which supplier filled it.

---

## 2. Current state

- `AggregatedList` has many `ProductMatch`es ([aggregated_list.rb](app/models/aggregated_list.rb)).
- `ProductMatch` ([product_match.rb](app/models/product_match.rb)): `canonical_name`, `match_status` (`confirmed | auto_matched | manual | unmatched`), `prices_by_supplier`, and `primary_item` = the `product_match_item` flagged `is_primary` → its `supplier_list_item`. `name` = `canonical_name || primary_item&.name`.
- `ProductMatchItem` links a match to a `supplier_list_item` per supplier (has `is_primary`).
- A `supplier_list_item` resolves to a `SupplierProduct` (by supplier + SKU) — the source of its thumbnail (PRD 1).
- `OrderListItem` ([order_list_item.rb](app/models/order_list_item.rb)) belongs to **either** `product` **or** `product_match`; `display_name = product&.name || product_match&.canonical_name`. Order lists and cart render from these.
- Matching UI today is **inline on the page**: `product_matches_controller`, `product_match_items_controller`, views under `app/views/product_match_items/` (incl. `no_match.turbo_stream.erb`), `_match_row_left.html.erb`, `match_filter_controller.js`.

---

## 3. Goals / Non-goals

### Goals
- Matching page is **display-only**; matching happens in a **modal** per row.
- Modal is a **lighter-weight** version of today's row matching.
- Modal sets **canonical name** + **canonical image** + the matches in one place.
- Modal shows the **primary thumbnail** and each **selected candidate's thumbnail** (visual match aid).
- Canonical image displays on the **product-match row, order lists, and cart** — display only.
- **Zero ordering-path regressions** (hard requirement).

### Non-goals
- No change to *how* matches are computed/auto-matched (AI/incremental matchers untouched).
- No custom canonical-image upload in v1 — pick among matched suppliers only.
- No canonical image for product-based order items that have no `ProductMatch` (fall back to nothing/placeholder in v1).
- No catalog-grid thumbnails (PRD 1 non-goal).

---

## 4. UX flow

1. **Matching page (display-only):** each row shows canonical name, canonical image (resolved), per-supplier prices, match status. No inline matching controls.
2. **Click a row → modal** (Turbo Frame), containing:
   - **Primary item** thumbnail + name (the current `primary_item`).
   - **Canonical name** field (editable; defaults to existing `canonical_name` or primary name).
   - **Canonical image picker:** the matched suppliers' thumbnails as selectable options; current selection highlighted. Default = primary's thumbnail until overridden.
   - **Candidate picker** (today's dropdown/search): add/select supplier items to the match. On select, render that item's thumbnail next to it.
   - **Save / Confirm** → persists matches, canonical name, canonical image; updates `match_status` as today.
3. Closing the modal returns to the (now updated) display-only row via Turbo Stream.

---

## 5. Data model changes

```ruby
# migration
add_column :product_matches, :canonical_image_supplier_product_id, :bigint  # chosen source thumbnail; nullable
add_index  :product_matches, :canonical_image_supplier_product_id
# canonical_name already exists on product_matches
```

```ruby
class ProductMatch < ApplicationRecord
  belongs_to :canonical_image_supplier_product, class_name: "SupplierProduct", optional: true

  # Resolution: explicit pick -> primary item's supplier_product -> nil (placeholder)
  def canonical_image_source
    canonical_image_supplier_product || primary_item_supplier_product
  end

  def canonical_thumb_url
    sp = canonical_image_source
    sp&.thumbnail&.attached? ? product_thumb_url(sp) : nil   # triggers lazy mirror via PRD 1 helper
  end

  private

  def primary_item_supplier_product
    primary_item&.supplier_product   # supplier_list_item -> SupplierProduct (supplier + sku)
  end
end
```

- **Validation:** `canonical_image_supplier_product_id`, when set, must belong to one of this match's own `product_match_items` (you can only pick among the matched suppliers).
- **On re-match:** if the chosen canonical source supplier item is removed from the match, null the column (falls back to primary).

---

## 6. Canonical image display surfaces

| Surface | Renders from | Helper |
|---|---|---|
| Product-match row (display-only page) | `ProductMatch` | `canonical_thumb_url` |
| Order list | `OrderListItem#product_match` | `order_list_item.product_match&.canonical_thumb_url` |
| Cart / order | same as order list | same |

- Match-based order items use the `ProductMatch` canonical image. Product-based items (no match) → placeholder in v1.
- All three are **read-only display** of an existing thumbnail → **no ordering-path interaction**.

---

## 7. The matching modal

- Reuse `product_match_items_controller` actions (add/remove/confirm) — **relocate** the existing UI into a Turbo-Frame modal rather than rewrite the matching logic.
- "Lighter weight" = trimmed layout + the thumbnail aid; the underlying create/update/destroy + `match_status` transitions + `is_primary` handling stay identical (see §8).
- Candidate thumbnails + primary thumbnail come from PRD 1's `product_thumb_url`; opening the modal warm-enqueues mirror jobs for primary + candidates.
- Canonical image picker posts the chosen `supplier_product_id` to a new `product_matches#set_canonical_image` action (+ `set_canonical_name` or reuse an update action).

---

## 8. ⚠️ Ordering-safety analysis (hard requirement)

Matching feeds ordering (`ProductMatch` → `OrderListItem` → orders), so this section gates the work.

- **Canonical name + image: display only.** They do not change which `supplier_list_item`/`supplier_product` is ordered. Safe by construction.
- **Moving matching into a modal must preserve, byte-for-byte, what the order flow depends on:**
  - `product_match_items` membership (which supplier items are in the match) — drives `prices_by_supplier` and `supplier_for(supplier)`.
  - `is_primary` designation.
  - `match_status` transitions (`confirmed`/`manual`/etc.).
- **Required before merge:** enumerate every field/transition today's inline matching writes, and assert the modal writes the same set. Cover with a spec that drives the modal path and asserts the resulting `ProductMatch`/`ProductMatchItem` state equals the inline path's, then places a dry-run order off the match.
- **Display-only page:** confirm no current code path depends on inline-edit controls being present on the page.
- Per project rule: flag any change touching `OrderPlacementService`, cart, scraper `add_to_cart`/`submit`, or price verification — **none expected here**, but re-verify the order-guide/`form_for_order` read path is untouched by PRD 1's added field.

---

## 9. Testing

- **Model:** `canonical_image_source` resolution (explicit → primary → nil); validation rejects a supplier_product not in the match; re-match nulls a dangling pick.
- **Controller/system:** open modal → thumbnails render (primary + candidates); pick canonical image → persists + row updates via Turbo Stream; set canonical name → persists.
- **Parity (ordering safety):** modal match-edit produces identical `ProductMatch`/`ProductMatchItem` state to the old inline flow; dry-run order off the resulting match succeeds.
- **Display:** order list + cart render canonical image for match-based items; placeholder for product-based.

---

## 10. Phased rollout

1. **P1 — Data + resolution:** migration, `ProductMatch#canonical_image_source/canonical_thumb_url`, validation. Display canonical image on the product-match row (defaults to primary). Invisible elsewhere.
2. **P2 — Modal:** relocate matching into the Turbo-Frame modal; add primary/candidate thumbnails; canonical name + image setters. Behind a flag (`MATCHING_MODAL_ENABLED`).
3. **P3 — Display-only page:** strip inline matching once the modal is the sole editor.
4. **P4 — Order list + cart** display of canonical image.

Depends on **PRD 1** being at least Phase 2 (thumbnails mirrorable) before P2 here.

---

## 11. Open questions / risks

- **"Lighter weight" scope:** is it purely relocation + thumbnails, or also slimming the matching controls (fewer fields)? (Assumed: relocation + thumbnails; logic unchanged.)
- **Primary vs. canonical-source divergence:** the chef's chosen canonical image may come from a non-primary supplier; confirm we never silently change `is_primary` when they pick a canonical image (we don't — separate concerns).
- **Match churn:** dangling canonical-source handling on re-match (resolved: null → fallback).
- **Product-based order items:** no canonical image in v1 (acceptable?).

---

## 12. Success metrics

- Chefs can set canonical name + image in the modal; the image appears on the row, order list, and cart.
- Match edits via the modal are state-identical to the old inline flow (parity spec green).
- Zero ordering-path regressions.
- Matching page render time improves or holds (display-only is lighter).
