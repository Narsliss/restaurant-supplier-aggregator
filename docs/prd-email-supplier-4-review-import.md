# Product Requirements Document: Review & Import UI

**Feature Name**: Price List Review & Import (MVP Step 4)
**Status**: Draft
**Date**: 2026-03-12
**Parent Feature**: Email Supplier Support
**Depends On**: PRD 1 (Database & Models), PRD 3 (PDF Upload & Parsing)

---

## 1. Executive Summary

After Claude AI parses a PDF price list, the chef needs to review the extracted products before they enter the system. This PRD covers the review page where chefs can inspect, edit, exclude, and import products — plus the import service that creates `SupplierList` and `SupplierListItem` records using the same patterns as the web-scraped import pipeline.

The key constraint: the parsed `raw_products_json` on `InboundPriceList` is **shared across orgs**. Per-org edits (renaming, excluding) are NOT saved back to the shared JSON — they're passed as form parameters during import. Each org imports independently.

---

## 2. Problem Statement

AI extraction isn't perfect. Product names might be truncated, prices misread, categories wrong. The chef needs a human-in-the-loop step to:

1. Verify the extraction looks correct (spot-check names and prices)
2. Exclude products they don't buy from this supplier
3. Edit product names, prices, or pack sizes if the AI got them wrong
4. Trigger the import, which feeds into the existing matched list pipeline

Without this review step, bad data silently enters the system and corrupts price comparisons.

---

## 3. User Stories

| # | As a... | I want to... | So that... |
|---|---------|-------------|------------|
| 1 | Chef | See all extracted products in a scannable table | I can quickly verify the AI got it right |
| 2 | Chef | Edit a product's name, price, or pack size inline | I can fix extraction errors before importing |
| 3 | Chef | Exclude specific products from import | I only import products I actually order |
| 4 | Chef | Import all (or selected) products with one click | The products appear in my matched list for price comparison |
| 5 | Chef | See price changes highlighted if I've imported from this supplier before | I know what changed since the last price list |
| 6 | Chef | Re-import from a newer PDF without losing my edits on the matched list | Weekly updates replace prices but preserve my confirmed matches |

---

## 4. Detailed Requirements

### 4.1 Review Page

**Route:** `GET /email_suppliers/:email_supplier_id/price_lists/:id/review`
**Controller:** `InboundPriceListsController#review`

**Prerequisites:**
- `InboundPriceList` must have `status: 'parsed'`
- User must belong to an org that has a `Supplier` with matching `contact_email`
- If status is `pending` or `parsing`: redirect to status page
- If status is `failed`: show error with re-upload option

**Page layout:**

```
┌──────────────────────────────────────────────────────────────────┐
│  Review Price List: Blue Ribbon Meats & Seafood                  │
│  📄 03.08.2026.pdf  ·  Mar 8, 2026  ·  120 products             │
│                                                                  │
│  ┌─────────────┐                                                 │
│  │ Select All  │  [Import Selected (120)]  [Re-parse]            │
│  └─────────────┘                                                 │
│                                                                  │
│  ── Pelagic Ocean Fish (12 items) ──────────────────────────     │
│                                                                  │
│  ☑  SKU   Name                    Price    Pack Size    Notes    │
│  ☑  200   #1 Tuna Loin           $25.99   per lb               │
│  ☑  201   Ahi Tuna #1 (2-4oz)    $27.99   per lb               │
│  ☐  202   Swordfish Loin         $18.99   per lb       ← excluded│
│  ☑  203   Mahi Mahi              $12.99   per lb       ▲ +$1.00 │
│                                                                  │
│  ── Ground Fish (8 items) ──────────────────────────────────     │
│  ...                                                             │
│                                                                  │
│  ┌─────────────────────────────────────────────────┐             │
│  │ Import Selected (118 of 120 products)           │             │
│  │                                                 │             │
│  │ This will create/update a supplier list for     │             │
│  │ "Blue Ribbon Meats" at [Current Location].      │             │
│  │ Products will appear in your matched list.      │             │
│  │                                                 │             │
│  │ [Cancel]                    [Import Products]   │             │
│  └─────────────────────────────────────────────────┘             │
└──────────────────────────────────────────────────────────────────┘
```

### 4.2 Product Table

**Data source:** `inbound_price_list.raw_products_json['products']`

**Columns:**

| Column | Width | Editable | Notes |
|--------|-------|----------|-------|
| Checkbox | 40px | yes | Include/exclude from import |
| SKU | 80px | no | Read-only (from extraction) |
| Name | flex | yes | Inline text editing |
| Price | 100px | yes | Inline number editing |
| Pack Size | 120px | yes | Inline text editing |
| Notes | 120px | no | "market price", "pre-order", etc. |
| Price Change | 80px | no | Only shown if prior import exists |

**Grouping:** Products are grouped by `category` (from extraction). Each group has a collapsible header showing category name and item count. Categories are shown in the order they appear in the PDF.

**Price change indicators** (only shown when the supplier has existing `SupplierListItem` records from a prior import):
- Price increased: red up arrow + dollar amount (e.g., "▲ +$1.00")
- Price decreased: green down arrow + dollar amount (e.g., "▼ -$0.50")
- New product (no prior): blue "NEW" badge
- Unchanged: no indicator

**Matching prior items:** Match by SKU first, then by normalized name (same logic as `SupplierListItem#link_to_supplier_product!`). The comparison is done client-side from data attributes, or server-side in the controller and passed as a map.

### 4.3 Inline Editing

**Stimulus controller:** `price-list-review`

Editable cells use contenteditable or inline inputs (toggled on click/focus). Changes are stored in hidden form fields that override the `raw_products_json` values on submit.

**Form structure:**
```html
<form action="/email_suppliers/5/price_lists/7/import" method="post">
  <!-- For each product -->
  <input type="hidden" name="products[0][sku]" value="200">
  <input type="hidden" name="products[0][name]" value="#1 Tuna Loin">
  <input type="hidden" name="products[0][price]" value="25.99">
  <input type="hidden" name="products[0][pack_size]" value="per lb">
  <input type="hidden" name="products[0][category]" value="Pelagic Ocean Fish">
  <input type="hidden" name="products[0][included]" value="1">
  <!-- ... -->
</form>
```

The key design decision: **edits are ephemeral.** They exist only in the form submission. The shared `raw_products_json` is never modified. If the chef navigates away without importing, edits are lost. This is intentional — each org's edits are independent.

### 4.4 Select All / Deselect All

- "Select All" checkbox in the header toggles all product checkboxes
- Per-category "Select All" checkbox toggles all products in that category
- Counter in the import button updates dynamically: "Import Selected (118 of 120)"

### 4.5 Import Action

**Route:** `POST /email_suppliers/:email_supplier_id/price_lists/:id/import`
**Controller:** `InboundPriceListsController#import`

**Parameters:**
```ruby
params[:products] # Array of product hashes with edits + included flag
```

**Flow:**
1. Find the email supplier for current org
2. Filter to only `included == '1'` products
3. Call `ImportEmailPriceListService.new(inbound_price_list, supplier, filtered_products).call`
4. Redirect to the supplier list or matched list page with flash: "Imported 118 products from Blue Ribbon Meats."

### 4.6 ImportEmailPriceListService

**New file:** `app/services/import_email_price_list_service.rb`

**Follows the pattern from `ImportSupplierListsService`** but instead of scraping, it reads from the form-submitted product array.

```ruby
class ImportEmailPriceListService
  attr_reader :price_list, :supplier, :products, :results

  def initialize(price_list, supplier, products)
    @price_list = price_list
    @supplier = supplier
    @products = products  # Array of hashes from form params
    @results = { items_imported: 0, items_updated: 0, errors: [] }
  end

  def call
    org = supplier.organization

    # Find or create the SupplierList for this email supplier + org
    supplier_list = SupplierList.find_or_initialize_by(
      supplier: supplier,
      organization: org,
      remote_list_id: "email-#{supplier.id}"  # Stable ID for dedup across imports
    )

    supplier_list.assign_attributes(
      name: supplier.name,
      list_type: 'managed',
      supplier_credential: nil,  # No credential for email suppliers
      inbound_price_list: price_list,
      sync_status: 'syncing'
    )
    supplier_list.save!

    # Upsert items (reuse ImportSupplierListsService pattern)
    existing_items_by_sku = supplier_list.supplier_list_items.index_by(&:sku)
    seen_skus = Set.new

    products.each_with_index do |product, index|
      upsert_item(supplier_list, product, existing_items_by_sku, seen_skus, index)
    end

    # Mark items not in this import as missed (staleness tracking)
    track_missing_items(supplier_list, seen_skus)

    supplier_list.update!(
      sync_status: 'synced',
      last_synced_at: Time.current,
      product_count: seen_skus.size
    )

    results
  end

  private

  def upsert_item(supplier_list, product_data, existing_items_by_sku, seen_skus, position)
    sku = product_data[:sku].to_s.strip
    # Generate a synthetic SKU if none provided (use position-based)
    sku = "email-#{position}" if sku.blank?

    seen_skus << sku

    item = existing_items_by_sku[sku] || supplier_list.supplier_list_items.build(sku: sku)
    is_new = item.new_record?

    # Track price changes
    new_price = product_data[:price].to_f
    if !is_new && new_price > 0 && item.price.present? && new_price != item.price
      item.previous_price = item.price
      item.price_updated_at = Time.current
    end

    item.assign_attributes(
      name: product_data[:name].to_s.truncate(255),
      price: new_price > 0 ? new_price : nil,
      pack_size: product_data[:pack_size],
      in_stock: true,  # On the PDF = available
      position: position
    )
    item.save!

    item.link_to_supplier_product! if item.supplier_product_id.nil?
    refresh_linked_product(item) if item.supplier_product_id.present?

    results[is_new ? :items_imported : :items_updated] += 1
  rescue StandardError => e
    results[:errors] << "Item '#{product_data[:name]}': #{e.message}"
  end

  def refresh_linked_product(item)
    # Same pattern as ImportSupplierListsService#refresh_linked_product
    sp = item.supplier_product
    return unless sp

    attrs = { last_scraped_at: Time.current }

    effective_price = item.estimated_total_price
    if effective_price.present? && effective_price != sp.current_price
      attrs[:previous_price] = sp.current_price
      attrs[:current_price] = effective_price
      attrs[:price_updated_at] = Time.current
    end

    attrs[:in_stock] = item.in_stock
    attrs[:pack_size] = item.pack_size if item.pack_size.present?

    sp.update!(attrs)
    sp.record_seen! if sp.consecutive_misses > 0 || sp.discontinued?
  end

  def track_missing_items(supplier_list, seen_skus)
    # Items that existed before but weren't in this PDF
    missing = supplier_list.supplier_list_items.where.not(sku: seen_skus.to_a)
    missing.find_each do |item|
      next unless item.supplier_product
      item.supplier_product.record_miss!
    end
  end
end
```

### 4.7 Integration with Matched Lists

After `SupplierList` is created/updated:
1. The existing `auto_add_to_matched_list` callback on `SupplierList` fires (defined in `app/models/supplier_list.rb:28`)
2. This links the email supplier's list to the location's master matched list
3. `SyncNewProductsJob` is triggered, which runs AI matching for new products
4. Products from the email supplier appear alongside web-scraped suppliers in price comparison

**No additional code needed for matched list integration.** The existing callbacks handle it.

### 4.8 Re-import Flow (Weekly Updates)

When the chef uploads a new PDF next week:
1. New `InboundPriceList` created (different `pdf_content_hash`)
2. Parsed via Claude API
3. Chef reviews on the review page
4. On import, `ImportEmailPriceListService` finds the **existing** `SupplierList` (via `find_or_initialize_by` with `remote_list_id: "email-#{supplier.id}"`)
5. Items are upserted by SKU — prices update, new items added
6. Items missing from the new PDF get `record_miss!` called on their linked `SupplierProduct`
7. The `SupplierList.inbound_price_list_id` updates to the new price list

**Price change detection on review page:** On subsequent reviews, the controller compares the new `raw_products_json` against existing `SupplierListItem` records by SKU to generate the price change indicators.

---

## 5. Controller Details

### InboundPriceListsController

```ruby
class InboundPriceListsController < ApplicationController
  before_action :require_operator!
  before_action :require_location_context!
  before_action :set_email_supplier
  before_action :set_price_list, only: [:show, :status, :review, :import]

  # POST /email_suppliers/:email_supplier_id/price_lists/upload
  def upload
    # See PRD 3
  end

  # GET /email_suppliers/:email_supplier_id/price_lists/:id
  def show
    # Status/waiting page (see PRD 3)
  end

  # GET /email_suppliers/:email_supplier_id/price_lists/:id/status
  def status
    render json: {
      status: @price_list.status,
      product_count: @price_list.product_count,
      error_message: @price_list.error_message,
      redirect_to: @price_list.parsed? ? review_email_supplier_price_list_path(@email_supplier, @price_list) : nil
    }
  end

  # GET /email_suppliers/:email_supplier_id/price_lists/:id/review
  def review
    redirect_to email_supplier_price_list_path(@email_supplier, @price_list) unless @price_list.parsed?

    @products = @price_list.raw_products_json['products'] || []
    @categories = @products.group_by { |p| p['category'] || 'Uncategorized' }

    # Load existing items for price change comparison
    existing_list = SupplierList.find_by(
      supplier: @email_supplier,
      organization: current_organization
    )
    @existing_items_by_sku = existing_list&.supplier_list_items&.index_by(&:sku) || {}
  end

  # POST /email_suppliers/:email_supplier_id/price_lists/:id/import
  def import
    products = (params[:products] || [])
      .select { |p| p[:included] == '1' }
      .map(&:to_unsafe_h)

    if products.empty?
      redirect_to review_email_supplier_price_list_path(@email_supplier, @price_list),
                  alert: "No products selected for import."
      return
    end

    result = ImportEmailPriceListService.new(@price_list, @email_supplier, products).call

    if result[:errors].any?
      flash[:warning] = "Imported with #{result[:errors].size} errors. #{result[:items_imported]} new, #{result[:items_updated]} updated."
    else
      flash[:notice] = "Imported #{result[:items_imported] + result[:items_updated]} products from #{@email_supplier.name}."
    end

    redirect_to supplier_credentials_path
  end

  private

  def set_email_supplier
    @email_supplier = Supplier.email_suppliers
                              .where(organization: current_organization)
                              .find(params[:email_supplier_id])
  end

  def set_price_list
    @price_list = InboundPriceList.find(params[:id])
    # Verify this price list belongs to the email supplier's contact_email
    unless @price_list.contact_email == @email_supplier.contact_email
      redirect_to supplier_credentials_path, alert: "Price list not found."
    end
  end
end
```

---

## 6. Edge Cases

| Scenario | Behavior |
|----------|----------|
| Products with no SKU in the PDF | Generate synthetic SKU: `"email-#{position}"`. Stable across re-imports if product order doesn't change. If order changes, items may be duplicated — acceptable for MVP. |
| Product with "Market Price" (no numeric price) | Display "Market Price" in the price column (not editable to a number). Imported with `price: nil`. Shows in matched list without a price. |
| Chef excludes all products | Import button disabled. Flash: "No products selected." |
| Two orgs import from the same `InboundPriceList` | Each creates their own `SupplierList` with their own `SupplierListItem` records. The shared `raw_products_json` is read-only. |
| Chef navigates away during editing without importing | Edits are lost (form state only). No data is saved. Expected behavior. |
| PDF has 500+ products | Table may be slow to render. Add virtual scrolling or pagination if needed post-MVP. For MVP, render all rows — 500 rows of simple table data is manageable. |
| AI misses a product or invents one | Chef can't add missing products on the review page (out of scope for MVP). They can exclude invented ones. For missing products, re-parse or manually add to the supplier list later. |
| Import fails midway | Transaction wraps the entire import. On failure, nothing is saved. Flash error with details. |

---

## 7. Stimulus Controller

### `price-list-review` controller

**Targets:**
- `selectAll` — master checkbox
- `productCheckbox` — per-product checkboxes
- `importButton` — shows selected count
- `editableCell` — cells that support inline editing

**Actions:**
- `toggleAll` — check/uncheck all products
- `toggleProduct` — update count on import button
- `editCell` — make cell editable on click
- `saveCell` — update hidden input on blur

**Values:**
- `totalCount` — total number of products
- `selectedCount` — number of checked products (updates import button text)

---

## 8. Out of Scope

- Adding products not in the PDF (manual product creation on review page)
- Bulk editing (e.g., apply 5% markup to all prices)
- Auto-import without review (always require human review for MVP)
- Saving review edits as a draft (edits exist only in the form)
- Re-parse button → addressed as a simple link back to upload page for MVP
