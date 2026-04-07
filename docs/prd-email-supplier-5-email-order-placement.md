# Product Requirements Document: Email Order Placement

**Feature Name**: Email Order Placement (MVP Step 5)
**Status**: Draft
**Date**: 2026-03-12
**Parent Feature**: Email Supplier Support
**Depends On**: PRD 1 (Database & Models), PRD 4 (Review & Import)

---

## 1. Executive Summary

For web-scraped suppliers, orders are placed by automating the supplier's website (scraper adds items to cart, proceeds through checkout). Email suppliers don't have websites — orders are placed by **sending an email** with an attached PDF order form to the supplier's `contact_email`.

This PRD covers the `EmailOrderPlacementService`, the order PDF generation (via Prawn), and the `SupplierOrderMailer` that delivers the order. It integrates with the existing `OrderPlacementService` dispatch pattern — when an order's supplier is an email type, the system routes to the email service instead of the scraper.

---

## 2. Problem Statement

The current `OrderPlacementService` assumes every supplier has a scraper. It calls `order.supplier.scraper_klass.new(credential)` to get a scraper instance, then drives the checkout flow. For email suppliers:
- There is no `scraper_class` (it's nil)
- There is no `SupplierCredential`
- There is no cart, checkout, or price verification

The order needs to be rendered as a professional PDF and emailed to the supplier. The chef expects the supplier to receive it just like a phone/email order — with restaurant name, items, quantities, and a delivery request.

---

## 3. User Stories

| # | As a... | I want to... | So that... |
|---|---------|-------------|------------|
| 1 | Chef | Place an order for an email supplier the same way I place any order | My workflow doesn't change based on supplier type |
| 2 | Chef | Have the system email my order to the supplier automatically | I don't have to manually compose an email with my order |
| 3 | Supplier (email recipient) | Receive a clear, professional order PDF | I can fulfill the order without confusion |
| 4 | Chef | See a confirmation that the order email was sent | I know the order went through |
| 5 | Chef | Have the supplier's reply come to my email, not the system's | I can communicate directly with the supplier about the order |

---

## 4. Detailed Requirements

### 4.1 Integration with OrderPlacementService

**File:** `app/services/orders/order_placement_service.rb`

Add an early branch at the top of `place_order`, before credential/scraper initialization:

```ruby
def place_order(accept_price_changes: false, skip_warnings: false, skip_pre_validation: false)
  # Email suppliers: route to email-based order placement
  if order.supplier.email_supplier?
    return Orders::EmailOrderPlacementService.new(order).place_order
  end

  # ... existing scraper-based flow ...
end
```

This must come before `get_active_credential` and `order.supplier.scraper_klass` — both would fail for email suppliers.

### 4.2 EmailOrderPlacementService

**New file:** `app/services/orders/email_order_placement_service.rb`

```ruby
module Orders
  class EmailOrderPlacementService
    attr_reader :order

    def initialize(order)
      @order = order
    end

    def place_order
      # Step 1: Validate the order has items
      validate_order!

      # Step 2: Mark order as processing
      order.update!(status: 'processing')

      # Step 3: Generate order PDF
      pdf_data = generate_order_pdf

      # Step 4: Send email with PDF attachment
      SupplierOrderMailer.order_email(order, pdf_data).deliver_now

      # Step 5: Mark order as submitted
      confirmation_number = "EMAIL-#{Time.current.strftime('%Y%m%d%H%M%S')}-#{order.id}"
      order.update!(
        status: 'submitted',
        confirmation_number: confirmation_number,
        submitted_at: Time.current,
        total_amount: order.calculated_subtotal
      )
      order.order_items.update_all(status: 'added')

      Rails.logger.info "[EmailOrderPlacement] Order #{order.id} emailed to #{order.supplier.contact_email}"

      { success: true, order: order.reload }
    rescue StandardError => e
      order.update!(
        status: 'failed',
        notes: [order.notes, "Email order failed: #{e.message}"].compact.join("\n\n")
      )
      Rails.logger.error "[EmailOrderPlacement] Order #{order.id} failed: #{e.class}: #{e.message}"

      { success: false, error: e.message, order: order.reload }
    end

    private

    def validate_order!
      raise "No items in order" if order.order_items.empty?
      raise "Supplier has no contact email" if order.supplier.contact_email.blank?
    end

    def generate_order_pdf
      OrderPdfGenerator.new(order).generate
    end
  end
end
```

**Key differences from web OrderPlacementService:**
- No credential lookup (email suppliers don't have credentials)
- No scraper initialization
- No cart building, price verification, or checkout
- No dry-run mode (email orders are always "real" — the email is sent)
- No 2FA handling
- Simpler error handling (no scraper-specific exceptions)

### 4.3 OrderPdfGenerator (Prawn)

**New file:** `app/services/orders/order_pdf_generator.rb`

**New gem:** Add `gem 'prawn'` and `gem 'prawn-table'` to Gemfile.

Generates a professional order PDF with:

```
┌──────────────────────────────────────────────────┐
│                                                  │
│  ORDER                                           │
│  From: Las Noches Mexican Restaurant             │
│  123 Main St, Austin, TX 78701                   │
│  Phone: (512) 555-0100                           │
│  Email: chef@las-noches.com                      │
│                                                  │
│  To: Blue Ribbon Meats & Seafood                 │
│  orders@blueribbonmeats.com                      │
│                                                  │
│  Order Date: March 12, 2026                      │
│  Requested Delivery: March 14, 2026              │
│  Order #: EMAIL-20260312143022-47                │
│                                                  │
│  ┌──────┬────────────────────┬─────┬───────┬────┐│
│  │ Qty  │ Item               │ SKU │ Unit  │ Est││
│  │      │                    │     │ Price │ Tot││
│  ├──────┼────────────────────┼─────┼───────┼────┤│
│  │  5   │ #1 Tuna Loin       │ 200 │$25.99 │$129││
│  │      │                    │     │  /lb  │.95 ││
│  │  3   │ Mahi Mahi          │ 203 │$12.99 │ $38││
│  │      │                    │     │  /lb  │.97 ││
│  │ 10   │ Jumbo Shrimp 16/20 │ 305 │$14.99 │$149││
│  │      │                    │     │  /lb  │.90 ││
│  ├──────┴────────────────────┴─────┼───────┼────┤│
│  │                    Estimated    │       │$318││
│  │                       Total:    │       │.82 ││
│  └─────────────────────────────────┴───────┴────┘│
│                                                  │
│  Notes:                                          │
│  Please deliver to back loading dock.            │
│                                                  │
│  ──────────────────────────────────────────────  │
│  Generated by EnPlace Pro · supplierhub.com      │
│                                                  │
└──────────────────────────────────────────────────┘
```

**Implementation:**

```ruby
module Orders
  class OrderPdfGenerator
    def initialize(order)
      @order = order
    end

    def generate
      Prawn::Document.new(page_size: 'LETTER', margin: 50) do |pdf|
        header(pdf)
        addresses(pdf)
        order_details(pdf)
        items_table(pdf)
        notes(pdf)
        footer(pdf)
      end.render  # Returns binary PDF data
    end

    private

    def header(pdf)
      pdf.text "ORDER", size: 24, style: :bold
      pdf.move_down 20
    end

    def addresses(pdf)
      # From: restaurant info
      # To: supplier info
    end

    def order_details(pdf)
      # Order date, delivery date, order number
    end

    def items_table(pdf)
      # Prawn::Table with order items
      data = [["Qty", "Item", "SKU", "Unit Price", "Est. Total"]]

      @order.order_items.includes(:supplier_product).each do |item|
        data << [
          item.quantity,
          item.supplier_product&.supplier_name || item.product_name,
          item.supplier_product&.supplier_sku || "—",
          format_price(item.unit_price),
          format_price(item.line_total)
        ]
      end

      # Total row
      data << ["", "", "", "Estimated Total:", format_price(@order.calculated_subtotal)]

      pdf.table(data, width: pdf.bounds.width) do |table|
        table.row(0).font_style = :bold
        table.row(-1).font_style = :bold
        # ... styling
      end
    end

    def notes(pdf)
      return unless @order.notes.present?
      pdf.move_down 20
      pdf.text "Notes:", style: :bold
      pdf.text @order.notes
    end

    def footer(pdf)
      pdf.move_down 30
      pdf.stroke_horizontal_rule
      pdf.move_down 10
      pdf.text "Generated by EnPlace Pro", size: 8, color: "999999"
    end

    def format_price(amount)
      return "—" unless amount
      "$#{'%.2f' % amount}"
    end
  end
end
```

### 4.4 SupplierOrderMailer

**New file:** `app/mailers/supplier_order_mailer.rb`

```ruby
class SupplierOrderMailer < ApplicationMailer
  def order_email(order, pdf_data)
    @order = order
    @supplier = order.supplier
    @location = order.location
    @organization = order.organization || order.user.current_organization

    attachments["order-#{order.id}-#{Date.current.iso8601}.pdf"] = {
      mime_type: 'application/pdf',
      content: pdf_data
    }

    mail(
      to: @supplier.contact_email,
      reply_to: order.user.email,
      subject: "Order from #{@organization.name} - #{Date.current.strftime('%b %d, %Y')}"
    )
  end
end
```

**Email body** (`app/views/supplier_order_mailer/order_email.text.erb`):

```
Order from <%= @organization.name %>
<%= @location&.name %>

Order Date: <%= Date.current.strftime('%B %d, %Y') %>
Requested Delivery: <%= @order.delivery_date&.strftime('%B %d, %Y') || 'Next available' %>

Items:
<% @order.order_items.each do |item| %>
  - <%= item.quantity %>x <%= item.supplier_product&.supplier_name || item.product_name %> (<%= item.supplier_product&.supplier_sku %>)
<% end %>

Estimated Total: $<%= '%.2f' % @order.calculated_subtotal %>

<% if @order.notes.present? %>
Notes: <%= @order.notes %>
<% end %>

Please see attached PDF for the complete order.

Thank you,
<%= @order.user.name %>
<%= @order.user.email %>
```

**Key decisions:**
- `to:` is the supplier's `contact_email` — the same address they send price lists from
- `reply_to:` is the ordering chef's email — supplier replies go directly to the chef, not the system
- `from:` uses the default `ApplicationMailer` from address (system email)
- Plain text body as a summary + PDF attachment as the formal order
- No HTML email template (suppliers are used to plain text orders)

### 4.5 Order Lifecycle for Email Suppliers

| Step | Status | What Happens |
|------|--------|-------------|
| Chef builds order from matched list | `pending` | Same as web suppliers |
| Chef clicks "Place Order" | `processing` | `EmailOrderPlacementService` takes over |
| PDF generated + email sent | `submitted` | `confirmation_number` set to `"EMAIL-{timestamp}-{id}"` |
| (failure) | `failed` | Error recorded in `notes` |

**No verification flow:** Email suppliers don't support price verification (no website to check against). The `verification_status` is set to `'skipped'` with reason "Email supplier — no online verification available."

**No dry-run mode:** There's no meaningful dry-run for an email order. The email is either sent or not. In development, `ActionMailer` uses `letter_opener` so emails are captured locally without actually sending.

### 4.6 Order Safety

The existing two-layer safety model doesn't apply to email suppliers the same way:

1. **`checkout_enabled` flag:** Still checked. If `checkout_enabled = false`, the email is NOT sent. Instead, the order is marked as `dry_run_complete` with a note explaining the PDF was generated but not emailed.
2. **Development environment:** `letter_opener` intercepts all outgoing email, so no real email is sent in development regardless of `checkout_enabled`.
3. **Order minimums:** Email suppliers may optionally have `SupplierRequirement` records for minimum order amounts. If set, the same minimum validation runs. If not set (most email suppliers), no minimum is enforced.

```ruby
# In EmailOrderPlacementService:
def should_send_email?
  return false unless Rails.env.production?
  order.supplier.checkout_enabled?
end
```

### 4.7 Confirmation UI

After successful placement, the order show page displays:
- Status: "Submitted" (green badge)
- Confirmation #: `EMAIL-20260312143022-47`
- Note: "Order emailed to orders@blueribbonmeats.com"
- "Download Order PDF" link (regenerate on demand or store in Active Storage)

---

## 5. Gem Dependencies

| Gem | Purpose | Notes |
|-----|---------|-------|
| `prawn` | PDF generation | Mature, well-maintained, Ruby-native |
| `prawn-table` | Table layout in PDF | Extension for prawn, handles column alignment |

Add to Gemfile:
```ruby
gem 'prawn', '~> 2.5'
gem 'prawn-table', '~> 0.2'
```

---

## 6. Edge Cases

| Scenario | Behavior |
|----------|----------|
| Supplier `contact_email` is blank | `validate_order!` raises error. Order marked as failed with "Supplier has no contact email." |
| Order has 0 items | `validate_order!` raises error. Order marked as failed. |
| Email delivery fails (SMTP error) | `deliver_now` raises exception. Caught by rescue, order marked as failed with SMTP error message. |
| Chef places order for email supplier in development | `letter_opener` intercepts the email. Order marked as `dry_run_complete` (not `submitted`) since `checkout_enabled` is false in dev. |
| Order has items with nil prices (market price products) | PDF shows "Market Price" instead of a dollar amount. Line total shows "—". Estimated total excludes these items with a note: "* Items at market price not included in total." |
| Very large order (100+ items) | PDF may span multiple pages. Prawn handles pagination natively. Table continues on next page with repeated header row. |
| Supplier never receives the email (spam filter, wrong address) | No automatic detection. Chef should follow up directly. Post-MVP: delivery tracking via SendGrid webhooks. |
| Chef wants to re-send the order | "Re-send Order" button on order show page calls `SupplierOrderMailer.order_email(order, regenerated_pdf).deliver_now` without creating a new order. |

---

## 7. Order Flow Comparison

| Aspect | Web Supplier | Email Supplier |
|--------|-------------|----------------|
| Credential required | Yes | No |
| Price verification | Yes (scraper checks live prices) | No (skip verification) |
| Cart building | Scraper adds items to supplier's cart | N/A |
| Checkout | Scraper navigates checkout flow | Email sent with PDF |
| Dry-run mode | Scraper completes flow without final submit | PDF generated but email not sent |
| Confirmation | Supplier's order number from website | System-generated `EMAIL-{timestamp}` |
| Delivery date | Supplier returns confirmed date | Requested date passed through (no confirmation) |
| Order minimum | Checked via scraper + DB requirement | Checked via DB requirement only (if set) |
| 2FA handling | May require mid-flow 2FA code | N/A |

---

## 8. Out of Scope

- Order tracking / delivery confirmation (supplier replies via email to chef directly)
- Re-order from previous email order (uses standard matched list re-order flow)
- HTML email template (plain text + PDF is sufficient for supplier communication)
- Storing the generated PDF permanently (can be regenerated on demand; consider Active Storage attachment post-MVP)
- SendGrid delivery webhooks for email tracking → Post-MVP
