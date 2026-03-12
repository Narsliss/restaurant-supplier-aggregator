# Product Requirements Document: Email Supplier — Database & Model Foundation

**Feature Name**: Email Supplier Database & Model Foundation (MVP Step 1)
**Status**: Draft
**Date**: 2026-03-12
**Parent Feature**: Email Supplier Support

---

## 1. Executive Summary

SupplierHub currently supports four web-scraped suppliers (US Foods, Chef's Warehouse, What Chefs Want, Premiere Produce One). Many restaurants also buy from small, local suppliers who don't have websites — they send weekly PDF price lists via email, and orders are placed by replying with an email.

This PRD covers the database and model changes needed to support a new `email` auth type for suppliers, plus a new `InboundPriceList` model that stores parsed PDF price list data. These are the foundational data structures that all subsequent Email Supplier features build on.

---

## 2. Problem Statement

The current `Supplier` model assumes every supplier has a website (`base_url`, `login_url`, `scraper_class` are required). The `auth_type` enum only covers `password`, `two_fa`, and `welcome_url` — all web login methods. There is no way to represent a supplier whose only interface is email.

Additionally, there is no storage model for PDF-sourced product data. Web suppliers store products via `SupplierProduct` records created by scrapers. Email suppliers need a new intermediary model (`InboundPriceList`) to hold the parsed PDF data before it is reviewed and imported into the existing `SupplierList` / `SupplierListItem` / `SupplierProduct` pipeline.

---

## 3. Requirements

### 3.1 Extend the Supplier Model

**New auth type:**
- Add `'email'` to `AUTH_TYPES` constant: `['password', 'two_fa', 'welcome_url', 'email']`

**New columns on `suppliers` table:**

| Column | Type | Nullable | Default | Purpose |
|--------|------|----------|---------|---------|
| `contact_email` | string | yes | nil | Supplier's email address (used for both sender matching AND order delivery) |
| `ordering_instructions` | text | yes | nil | Free-text ordering notes (e.g., "Order Mon by 10 AM for Wed delivery") |
| `organization_id` | bigint FK | yes | nil | NULL = system-wide web supplier; set = org-scoped email supplier |
| `created_by_id` | bigint FK | yes | nil | The user who created this email supplier |

**Indexes:**
- `index_suppliers_on_contact_email` — queried on every inbound email arrival to fan out to orgs
- `index_suppliers_on_organization_id` — scoping queries for org-specific suppliers

**Validation changes:**
- `base_url`, `login_url`, `scraper_class`: change from `validates :x, presence: true` to `validates :x, presence: true, unless: :email_supplier?`
- `contact_email`: `validates :contact_email, presence: true, if: :email_supplier?`
- `contact_email` format: validate email format when present
- Uniqueness: `validates :name, uniqueness: { scope: :organization_id }` for email suppliers (two suppliers with the same name in the same org is confusing)
- The existing `validates :code, uniqueness: true` still applies — email suppliers need a `code` too (auto-generated from `name.parameterize` + org_id)

**New helper methods:**
- `email_supplier?` — `auth_type == 'email'`
- `latest_price_list` — `InboundPriceList.where(contact_email: contact_email).order(received_at: :desc).first`
- `price_list_stale?` — true if no parsed `InboundPriceList` for this `contact_email` in the last 3 weeks

**New scopes:**
- `email_suppliers` — `where(auth_type: 'email')`
- `for_organization(org)` — `where(organization_id: [nil, org.id])` (returns both system suppliers AND org-scoped ones)

**New associations:**
- `belongs_to :organization, optional: true`
- `belongs_to :creator, class_name: 'User', foreign_key: :created_by_id, optional: true`

**Existing code impact:**
- `config/initializers/seed_suppliers.rb`: No changes needed. It uses `find_or_create_by!(code: ...)` which won't conflict with email suppliers (which have different codes). The `base_url`/`login_url`/`scraper_class` are set explicitly for seeded suppliers.
- `SupplierCredential`: Email suppliers don't use credentials. The existing `has_many :supplier_credentials` association remains; email suppliers just won't have any.
- `OrderPlacementService`: Addressed in PRD 5 (Email Order Placement). No model-level changes needed here.

### 3.2 Create InboundPriceList Model

**Purpose:** Stores a parsed PDF price list. Keyed by `contact_email` (the sender), NOT by any specific supplier or organization. When multiple orgs have a supplier with the same `contact_email`, they all reference the same `InboundPriceList` — parse once, fan out.

**Columns:**

| Column | Type | Nullable | Default | Purpose |
|--------|------|----------|---------|---------|
| `contact_email` | string | no | — | Sender email this was matched by (routing key) |
| `message_id` | string | yes | nil | Email message-id for dedup (post-MVP, when Action Mailbox is added) |
| `pdf_content_hash` | string | yes | nil | SHA256 of PDF binary for content dedup |
| `from_email` | string | yes | nil | Actual FROM header (may differ from `contact_email`) |
| `subject` | string | yes | nil | Email subject line |
| `received_at` | datetime | no | — | When the PDF was uploaded or email received |
| `status` | string | no | `'pending'` | Processing state |
| `error_message` | text | yes | nil | Parse failure details |
| `raw_products_json` | jsonb | yes | nil | Claude API extraction output |
| `pdf_file_name` | string | yes | nil | Original filename |
| `list_date` | date | yes | nil | Date extracted from PDF content |
| `product_count` | integer | yes | nil | Number of products extracted |

**Active Storage:**
- `has_one_attached :pdf` — the uploaded PDF file

**Status lifecycle:**
```
pending → parsing → parsed
                  → failed
```

**Status constants:**
```ruby
STATUSES = %w[pending parsing parsed failed].freeze
```

**Indexes:**
- Unique on `message_id` (where not null) — Action Mailbox dedup (post-MVP)
- Unique on `[contact_email, pdf_content_hash]` (where hash not null) — duplicate PDF dedup
- Index on `contact_email` — routing lookups
- Index on `[contact_email, received_at]` — latest-per-email queries

**Scopes:**
- `pending` — `where(status: 'pending')`
- `parsed` — `where(status: 'parsed')`
- `for_email(email)` — `where(contact_email: email)`
- `latest_for(email)` — `for_email(email).order(received_at: :desc).first`

**Key methods:**
- `matching_suppliers` — `Supplier.email_suppliers.where(contact_email: contact_email)`
- `parsed?`, `failed?`, `pending?` — status checks
- `purge_storage!` — `pdf.purge; update!(raw_products_json: nil)` — used by cleanup

**Validations:**
- `contact_email`: presence, format
- `status`: presence, inclusion in `STATUSES`
- `received_at`: presence

**No belongs_to associations.** This is intentional — the price list is shared across orgs and matched by the `contact_email` string, not an FK.

### 3.3 Extend SupplierList Model

**New column:**

| Column | Type | Nullable | Purpose |
|--------|------|----------|---------|
| `inbound_price_list_id` | bigint FK | yes | Tracks which price list import this list came from |

**New association:**
- `belongs_to :inbound_price_list, optional: true`

**Impact on existing behavior:**
- `supplier_credential_id` is already nullable — email supplier lists just set it to NULL
- `list_type` will use `'managed'` for email-imported lists (same as manually managed lists)
- The existing `auto_add_to_matched_list` callback fires normally — email supplier lists auto-integrate with matched lists
- `sync_status` is not meaningful for email supplier lists (they're not "synced" via scraping). Set to `'synced'` on import.

### 3.4 raw_products_json Schema

The `raw_products_json` column stores the Claude API extraction output. All orgs that import from this price list read from the same JSON — per-org edits are not stored here (they're passed as form params during import).

```json
{
  "products": [
    {
      "sku": "200",
      "name": "#1 Tuna Loin",
      "price": 25.99,
      "pack_size": "per lb",
      "category": "Pelagic Ocean Fish",
      "in_stock": true,
      "notes": "pre-order"
    }
  ],
  "list_date": "2026-03-06",
  "supplier_name": "Blue Ribbon Meats & Seafood",
  "ordering_deadlines": "Order Monday by 10:00 AM for Wednesday ship..."
}
```

---

## 4. Migration Details

### Migration 1: `AddEmailSupplierFieldsToSuppliers`
```ruby
add_column :suppliers, :contact_email, :string
add_column :suppliers, :ordering_instructions, :text
add_column :suppliers, :organization_id, :bigint
add_column :suppliers, :created_by_id, :bigint

add_index :suppliers, :contact_email
add_index :suppliers, :organization_id
add_foreign_key :suppliers, :organizations, column: :organization_id, on_delete: :cascade
add_foreign_key :suppliers, :users, column: :created_by_id, on_delete: :nullify
```

### Migration 2: `CreateInboundPriceLists`
```ruby
create_table :inbound_price_lists do |t|
  t.string :contact_email, null: false
  t.string :message_id
  t.string :pdf_content_hash
  t.string :from_email
  t.string :subject
  t.datetime :received_at, null: false
  t.string :status, null: false, default: 'pending'
  t.text :error_message
  t.jsonb :raw_products_json
  t.string :pdf_file_name
  t.date :list_date
  t.integer :product_count

  t.timestamps
end

add_index :inbound_price_lists, :message_id, unique: true, where: "message_id IS NOT NULL"
add_index :inbound_price_lists, [:contact_email, :pdf_content_hash], unique: true,
          where: "pdf_content_hash IS NOT NULL", name: 'idx_inbound_price_lists_dedup'
add_index :inbound_price_lists, :contact_email
add_index :inbound_price_lists, [:contact_email, :received_at]
```

### Migration 3: `AddInboundPriceListToSupplierLists`
```ruby
add_reference :supplier_lists, :inbound_price_list, foreign_key: true, null: true
```

---

## 5. Data Flow Diagram

```
                    ┌─────────────────┐
                    │   Chef uploads   │
                    │   PDF manually   │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │ InboundPriceList │  ← keyed by contact_email
                    │ (status: pending)│
                    │ pdf attached     │
                    └────────┬────────┘
                             │
                      ParsePriceListJob
                             │
                             ▼
                    ┌─────────────────┐
                    │ InboundPriceList │
                    │ (status: parsed) │
                    │ raw_products_json│
                    └────────┬────────┘
                             │
                    Chef reviews & imports
                             │
                    ┌────────┴────────┐
                    ▼                 ▼
            ┌──────────────┐  ┌──────────────┐
            │ SupplierList │  │SupplierList  │   ← one per org
            │ (Org A)      │  │ (Org B)      │
            └──────┬───────┘  └──────┬───────┘
                   │                 │
                   ▼                 ▼
            ┌──────────────┐  ┌──────────────┐
            │SupplierList  │  │SupplierList  │   ← items
            │Items (Org A) │  │Items (Org B) │
            └──────┬───────┘  └──────┬───────┘
                   │                 │
          auto_add_to_matched_list   │
                   │                 │
                   ▼                 ▼
            ┌──────────────┐  ┌──────────────┐
            │ Matched List │  │ Matched List │   ← existing system
            │ (Org A)      │  │ (Org B)      │
            └──────────────┘  └──────────────┘
```

---

## 6. Risks & Considerations

| Risk | Mitigation |
|------|------------|
| Email suppliers bypass the existing `SupplierCredential` pattern | Email suppliers simply don't create credentials. All existing credential-dependent code paths (validate, refresh_session, import_lists) are gated by `credential.present?` or won't be invoked for email suppliers. |
| `contact_email` as a routing key is fragile (supplier changes email) | UI allows editing `contact_email`. Historical `InboundPriceList` records retain their original `contact_email` for audit. |
| `code` uniqueness for email suppliers | Auto-generate `code` from `"email-#{name.parameterize}-#{organization_id}"` to avoid conflicts with system supplier codes |
| Large `raw_products_json` | Typical supplier PDFs have 50-200 products. At ~200 bytes per product, that's 10-40KB of JSON — well within JSONB comfort zone. Storage cleanup (post-MVP) purges old records. |
| Active Storage not yet configured | Need to run `bin/rails active_storage:install` if the migration hasn't been run. Schema shows `active_storage_blobs` already exists, so Active Storage is installed. |

---

## 7. Out of Scope (addressed in other PRDs)

- Email supplier management UI → PRD 2
- PDF upload controller + parsing service → PRD 3
- Review & import UI → PRD 4
- Email order placement → PRD 5
- Action Mailbox / SendGrid setup → Post-MVP
- Storage cleanup jobs → Post-MVP
- Staleness detection → Post-MVP
