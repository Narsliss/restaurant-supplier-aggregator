# Product Requirements Document: Email Supplier Management UI

**Feature Name**: Email Supplier Management UI (MVP Step 2)
**Status**: Draft
**Date**: 2026-03-12
**Parent Feature**: Email Supplier Support
**Depends On**: PRD 1 (Database & Model Foundation)

---

## 1. Executive Summary

This PRD covers the UI for creating, viewing, editing, and deleting email suppliers. Email suppliers appear on the existing Supplier Credentials page in a new section below the web-scraped credential cards. The "Add Email Supplier" flow collects a supplier name and contact email — no username, password, or scraper configuration needed.

---

## 2. Problem Statement

The current Supplier Credentials page (`/supplier_credentials`) only shows web-scraped suppliers that require login credentials. There's no entry point for a chef to add a supplier that operates via email + PDF. The chef needs a way to:

1. Register a new email-only supplier with minimal friction
2. See all their email suppliers alongside web suppliers
3. Edit supplier details (name, email, ordering instructions)
4. Delete an email supplier they no longer use
5. Navigate to the price list upload/review flow for each email supplier

---

## 3. User Stories

| # | As a... | I want to... | So that... |
|---|---------|-------------|------------|
| 1 | Restaurant owner/admin | Add an email supplier by entering just a name and email | I can start uploading their PDFs without any scraper/login setup |
| 2 | Chef | See all my email suppliers on the credentials page | I have one place to manage all supplier connections |
| 3 | Owner | Edit an email supplier's name or contact email | I can fix typos or update when a supplier changes their email |
| 4 | Owner | Delete an email supplier | I can remove suppliers I no longer work with |
| 5 | Chef | Click through to an email supplier's price lists | I can upload a new PDF or review past imports |

---

## 4. Detailed Requirements

### 4.1 Credentials Index Page Changes

**Location:** `app/views/supplier_credentials/index.html.erb`

Add a new section **below** the existing credential cards grid:

```
┌──────────────────────────────────────────────────────────────┐
│  Supplier Credentials                    [Set Case Minimums] │
│                                          [Add Credential]    │
│                                                              │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐           │
│  │ US Foods    │ │ Chef's WH   │ │ WCW         │           │
│  │ Active      │ │ Connected   │ │ Connected   │           │
│  │ ...         │ │ ...         │ │ ...         │           │
│  └─────────────┘ └─────────────┘ └─────────────┘           │
│                                                              │
│  ─────────────────────────────────────────────────────────── │
│                                                              │
│  Email Suppliers                         [Add Email Supplier]│
│                                                              │
│  ┌─────────────┐ ┌─────────────┐                            │
│  │ Blue Ribbon  │ │ Acme Fish   │                            │
│  │ Meats        │ │             │                            │
│  │              │ │             │                            │
│  │ orders@blue  │ │ fish@acme   │                            │
│  │ ribbon.com   │ │ .com        │                            │
│  │              │ │             │                            │
│  │ Last PDF:    │ │ No PDFs yet │                            │
│  │ Mar 8, 2026  │ │             │                            │
│  │ 120 products │ │             │                            │
│  │              │ │             │                            │
│  │ [Upload PDF] │ │ [Upload PDF]│                            │
│  │ [View Lists] │ │             │                            │
│  │    [Edit][X] │ │    [Edit][X]│                            │
│  └─────────────┘ └─────────────┘                            │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Email supplier card contents:**
- **Supplier name** (h3, bold)
- **Contact email** (small text, truncated)
- **Ordering instructions** (if present, small italic text, truncated with tooltip)
- **Last price list info** (if any `InboundPriceList` exists for this `contact_email`):
  - Date: `list_date` or `received_at`
  - Product count
  - Status badge: Parsed (green), Pending (amber), Failed (red)
- **Empty state** (if no price lists): "No price lists uploaded yet"
- **Action buttons:**
  - "Upload PDF" — links to upload flow (PRD 3)
  - "View Lists" — links to price list index for this supplier (only shown if at least one parsed list exists)
  - Edit icon — links to edit page
  - Delete icon — `button_to` with `turbo_confirm`

**Card styling:**
- Same `bg-white shadow rounded-lg p-4 flex flex-col` as credential cards
- Same grid: `grid gap-4 sm:grid-cols-2 xl:grid-cols-4`
- No "Validate", "Import", or session-related UI (not applicable)

**Empty state for the section:**
- If no email suppliers exist for the org, show:
  > "No email suppliers added. Add suppliers that send you PDF price lists via email."

### 4.2 Add Email Supplier Form

**Route:** `GET /email_suppliers/new`
**Controller:** `EmailSuppliersController#new`

**Form fields:**

| Field | Type | Required | Placeholder | Notes |
|-------|------|----------|-------------|-------|
| Supplier Name | text_field | yes | "Blue Ribbon Meats & Seafood" | Free text |
| Contact Email | email_field | yes | "orders@supplier.com" | The email address the supplier sends from AND receives orders at |
| Ordering Instructions | text_area | no | "Order Monday by 10 AM for Wednesday delivery..." | Optional notes about ordering schedule/requirements |

**Form behavior:**
- Standard Rails `form_with` (no Stimulus controller needed — no dynamic fields)
- On submit: create `Supplier` record with `auth_type: 'email'`, `organization_id: current_organization.id`, `created_by_id: current_user.id`
- Auto-generate `code` from `"email-#{name.parameterize}-#{organization_id}"`
- Auto-generate `base_url`, `login_url`, `scraper_class` as nil (validated conditionally)
- Redirect to `supplier_credentials_path` with flash: "Email supplier added. Upload a PDF price list to get started."

**Validation errors displayed inline** (same pattern as credential form).

### 4.3 Edit Email Supplier Form

**Route:** `GET /email_suppliers/:id/edit`
**Controller:** `EmailSuppliersController#edit`

Same form fields as Add, pre-populated. Additional display:
- Read-only "Created by" line showing `supplier.creator.name` and date
- If price lists exist, a note: "Changing the contact email will affect which future price lists are matched to this supplier."

### 4.4 Delete Email Supplier

**Route:** `DELETE /email_suppliers/:id`
**Controller:** `EmailSuppliersController#destroy`

**Confirmation dialog:** "Are you sure? This will remove [Supplier Name] and all imported lists. Products already in your matched list will not be affected."

**On delete:**
- Destroy the `Supplier` record
- Cascade deletes `SupplierList` records (via existing `has_many :supplier_lists, dependent: :destroy`)
- `SupplierListItem` records cascade from list deletion
- `SupplierProduct` records are NOT deleted (they may be referenced by matched lists, orders)
- `InboundPriceList` records are NOT deleted (they're shared across orgs, keyed by `contact_email`)

### 4.5 Controller: EmailSuppliersController

**New file:** `app/controllers/email_suppliers_controller.rb`

```ruby
class EmailSuppliersController < ApplicationController
  before_action :require_operator!  # owner or admin only
  before_action :require_location_context!
  before_action :set_supplier, only: [:edit, :update, :destroy]

  def new
    @supplier = Supplier.new(auth_type: 'email')
  end

  def create
    @supplier = Supplier.new(supplier_params)
    @supplier.auth_type = 'email'
    @supplier.organization = current_organization
    @supplier.created_by_id = current_user.id
    @supplier.code = generate_code(@supplier.name)
    # ...
  end

  def edit; end
  def update; end
  def destroy; end

  private

  def set_supplier
    @supplier = current_organization.suppliers.email_suppliers.find(params[:id])
  end

  def supplier_params
    params.require(:supplier).permit(:name, :contact_email, :ordering_instructions)
  end

  def generate_code(name)
    "email-#{name.parameterize}-#{current_organization.id}"
  end
end
```

**Authorization:** Only owners and admins can manage email suppliers (same as web credentials). The `require_operator!` before_action handles this.

**Scoping:** All queries scoped to `current_organization` — a chef can only see/manage their own org's email suppliers.

### 4.6 Routes

```ruby
resources :email_suppliers, only: [:new, :create, :edit, :update, :destroy]
```

---

## 5. Data Fetching for Credentials Index

The `SupplierCredentialsController#index` action needs additional data for the email suppliers section:

```ruby
# Existing
@credentials = current_location_credentials

# New
@email_suppliers = Supplier.email_suppliers
                           .where(organization_id: current_organization.id)
                           .order(:name)

# For each email supplier, preload latest price list info
@email_supplier_stats = InboundPriceList
  .where(contact_email: @email_suppliers.pluck(:contact_email))
  .select("contact_email, MAX(received_at) as last_received, MAX(product_count) as last_product_count, MAX(list_date) as last_list_date")
  .group(:contact_email)
  .index_by(&:contact_email)
```

This avoids N+1 queries — one query gets stats for all email suppliers.

---

## 6. Edge Cases

| Scenario | Behavior |
|----------|----------|
| Chef enters a `contact_email` already used by another org | Allowed — each org creates its own supplier. The `InboundPriceList` will be shared via `contact_email` matching. |
| Chef enters a `contact_email` already used by another supplier in the SAME org | Allowed — different suppliers might share an email (e.g., a distributor with multiple brands). But show a warning: "Another email supplier in your organization uses this email address." |
| Chef creates a duplicate supplier name in same org | Blocked by uniqueness validation on `[name, organization_id]` |
| Chef with `member` role tries to add an email supplier | Blocked by `require_operator!` — only owners/admins |
| Organization has no locations set up | Blocked by `require_location_context!` — same as web credentials |
| Supplier name contains special characters | `code` generation uses `parameterize` which handles this safely |
| Chef edits `contact_email` on a supplier that has imported lists | Lists remain linked via `inbound_price_list_id` on `SupplierList`. Future price lists will use the new email. Old `InboundPriceList` records retain their original `contact_email`. |

---

## 7. UI/UX Details

**"Add Email Supplier" button:**
- Style: `border border-brand-orange text-brand-orange hover:bg-brand-orange hover:text-white` (outlined, matches "Add Credential" visual hierarchy)
- Position: Top-right of the "Email Suppliers" section header

**Section divider:**
- Simple `border-t border-gray-200 mt-8 pt-6` between web credentials and email suppliers sections

**Card status indicators:**
- No "Active/Connected/Disconnected" badges (not applicable for email suppliers)
- Instead, show price list freshness:
  - Green badge: "Updated [X days ago]" (list_date within last 2 weeks)
  - Amber badge: "Last update [X weeks ago]" (2-4 weeks)
  - Red badge: "Stale — [X weeks ago]" (>4 weeks, post-MVP)
  - Gray badge: "No lists yet" (no imports)

---

## 8. Out of Scope

- PDF upload functionality → PRD 3
- Price list review/import → PRD 4
- Order placement via email → PRD 5
- Inline editing of supplier from card (edit links to separate page)
- Bulk import of multiple email suppliers
