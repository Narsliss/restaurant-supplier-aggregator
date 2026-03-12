# Product Requirements Document: PDF Upload & Parsing

**Feature Name**: PDF Upload & AI-Powered Price List Parsing (MVP Step 3)
**Status**: Draft
**Date**: 2026-03-12
**Parent Feature**: Email Supplier Support
**Depends On**: PRD 1 (Database & Model Foundation), PRD 2 (Email Supplier Management UI)

---

## 1. Executive Summary

This PRD covers the PDF upload flow and AI-powered parsing service. A chef uploads a PDF price list for an email supplier, the system sends it to the Claude API for structured extraction, and the parsed products are stored as JSON on an `InboundPriceList` record for review.

This is the core intelligence of the email supplier feature — it turns an unstructured PDF into structured product data (name, price, SKU, pack size, category) that can be imported into the existing `SupplierList` / `SupplierListItem` pipeline.

---

## 2. Problem Statement

Supplier price lists arrive as PDFs with wildly different formats — some are tables, some are multi-column layouts, some mix categories with products, some include ordering deadlines and notes. Traditional PDF parsing (tabula, pdf-reader) struggles with non-tabular layouts and requires per-supplier format configuration.

Using Claude's vision/document understanding API, we can handle arbitrary PDF formats with a single prompt — no per-supplier customization needed.

---

## 3. User Stories

| # | As a... | I want to... | So that... |
|---|---------|-------------|------------|
| 1 | Chef | Upload a PDF from my email supplier | The system can extract products and prices from it |
| 2 | Chef | See a loading state while the PDF is being parsed | I know the system is working and can come back later |
| 3 | Chef | Get notified if parsing fails | I can re-upload or contact support |
| 4 | Chef | Upload a replacement PDF if I uploaded the wrong one | I can correct mistakes |

---

## 4. Detailed Requirements

### 4.1 Upload Flow

**Entry point:** "Upload PDF" button on the email supplier card (from PRD 2), or a dedicated upload page.

**Route:** `POST /email_suppliers/:email_supplier_id/price_lists/upload`
**Controller:** `InboundPriceListsController#upload`

**Upload form:**
- Single file input: `file_field :pdf, accept: '.pdf'`
- Pre-selected email supplier (from URL param) — shown as read-only text, not a dropdown
- Submit button: "Upload & Parse"
- File size limit: 20MB (enforced client-side via `file_field` max attribute + server-side validation)

**On submit:**
1. Validate: PDF file present, file is actually a PDF (check MIME type), file size < 20MB
2. Compute `pdf_content_hash` = `Digest::SHA256.hexdigest(file.read)` (rewind file after)
3. Check for duplicate: `InboundPriceList.find_by(contact_email: supplier.contact_email, pdf_content_hash: hash)`
   - If found and `status == 'parsed'`: redirect to review page with flash "This PDF has already been parsed."
   - If found and `status == 'pending'` or `'parsing'`: redirect to status page with flash "This PDF is currently being processed."
   - If found and `status == 'failed'`: allow re-upload (create new record)
4. Create `InboundPriceList` record:
   - `contact_email`: from the email supplier's `contact_email`
   - `received_at`: `Time.current`
   - `pdf_file_name`: original filename
   - `pdf_content_hash`: computed hash
   - `status`: `'pending'`
5. Attach PDF via Active Storage: `inbound_price_list.pdf.attach(file)`
6. Enqueue `ParsePriceListJob.perform_later(inbound_price_list.id)`
7. Redirect to the price list show/status page

**Error handling:**
- No file selected: re-render form with error
- File not a PDF: re-render with "Please upload a PDF file"
- File too large: re-render with "File must be under 20MB"
- Unexpected error: flash error, re-render form

### 4.2 Status Page (Polling)

**Route:** `GET /email_suppliers/:email_supplier_id/price_lists/:id`
**Controller:** `InboundPriceListsController#show`

While the PDF is being parsed, show a status page:

```
┌──────────────────────────────────────────────┐
│  Parsing Price List                          │
│                                              │
│  📄 03.08.2026.pdf                           │
│  Uploaded just now                           │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │  ⏳ Processing your price list...      │  │
│  │                                        │  │
│  │  Claude AI is extracting products,     │  │
│  │  prices, and categories from your PDF. │  │
│  │  This usually takes 15-30 seconds.     │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  [Back to Supplier Credentials]              │
└──────────────────────────────────────────────┘
```

**Polling:**
- Stimulus controller (`price-list-status`) polls `GET /email_suppliers/:id/price_lists/:id/status.json` every 3 seconds
- JSON response: `{ status: "parsing", product_count: null }` or `{ status: "parsed", product_count: 120, redirect_to: "/email_suppliers/5/price_lists/7/review" }`
- On `parsed`: auto-redirect to review page (PRD 4)
- On `failed`: show error message inline with "Re-upload" button

**Route for status polling:**
```ruby
resources :price_lists, controller: 'inbound_price_lists' do
  member { get :status }
end
```

### 4.3 PdfParsingService

**New file:** `app/services/pdf_parsing_service.rb`

**Responsibility:** Takes an `InboundPriceList` with an attached PDF, sends it to the Claude API, and stores the structured extraction result.

**API Integration:**
- Uses `Faraday` directly (consistent with existing `AiProductMatcherService` pattern — that service calls Groq via Faraday)
- Endpoint: `https://api.anthropic.com/v1/messages`
- Model: `claude-sonnet-4-20250514` (good balance of cost/quality for document extraction)
- API key: `ENV['ANTHROPIC_API_KEY']`
- Max tokens: 8192 (large enough for 200+ products)

**Request structure:**
```ruby
{
  model: "claude-sonnet-4-20250514",
  max_tokens: 8192,
  messages: [{
    role: "user",
    content: [
      {
        type: "document",
        source: {
          type: "base64",
          media_type: "application/pdf",
          data: base64_encoded_pdf
        }
      },
      {
        type: "text",
        text: EXTRACTION_PROMPT
      }
    ]
  }]
}
```

**Extraction prompt:**
```
You are a food service product data extractor. Analyze this supplier price list PDF
and extract ALL products into structured JSON.

Return ONLY valid JSON with this exact structure:
{
  "products": [
    {
      "sku": "string or null (item/product number if shown)",
      "name": "string (product name exactly as printed)",
      "price": number (price as a decimal, e.g. 25.99),
      "pack_size": "string or null (e.g. '10 lb case', 'per lb', '24 ct')",
      "category": "string or null (section/category heading the product falls under)",
      "in_stock": true,
      "notes": "string or null (any special notes like 'pre-order', 'seasonal', 'market price')"
    }
  ],
  "list_date": "YYYY-MM-DD or null (date shown on the price list)",
  "supplier_name": "string or null (supplier/company name from header)",
  "ordering_deadlines": "string or null (any ordering cutoff info, delivery schedule, etc.)"
}

Rules:
- Extract EVERY product, even if some fields are missing
- Prices with "MP" or "Market Price" should set price to null and notes to "market price"
- If a product appears in multiple sections, include it once with the most specific category
- SKU is the item number, product code, or catalog number — NOT the product name
- Preserve the exact product name as printed (don't normalize or abbreviate)
- For pack_size, include the unit (lb, oz, ct, cs, ea, etc.)
- Set in_stock to true unless explicitly marked as out of stock or unavailable
- If no date is visible on the PDF, set list_date to null
```

**Service flow:**
```ruby
class PdfParsingService
  ANTHROPIC_API_URL = 'https://api.anthropic.com/v1/messages'.freeze
  MODEL = 'claude-sonnet-4-20250514'.freeze
  MAX_TOKENS = 8192

  def initialize(inbound_price_list)
    @price_list = inbound_price_list
    @api_key = ENV['ANTHROPIC_API_KEY']
  end

  def call
    @price_list.update!(status: 'parsing')

    pdf_data = download_pdf
    response = call_claude_api(pdf_data)
    parsed = extract_json(response)

    @price_list.update!(
      status: 'parsed',
      raw_products_json: parsed,
      product_count: parsed['products']&.size || 0,
      list_date: parse_date(parsed['list_date']),
      error_message: nil
    )

    { success: true, product_count: @price_list.product_count }
  rescue => e
    @price_list.update!(
      status: 'failed',
      error_message: "#{e.class}: #{e.message}"
    )
    { success: false, error: e.message }
  end

  private

  def download_pdf
    @price_list.pdf.download
  end

  def call_claude_api(pdf_binary)
    # Faraday POST to Anthropic API with base64-encoded PDF
  end

  def extract_json(response)
    # Parse the text content from Claude's response
    # Handle potential markdown code fences around JSON
    # JSON.parse the result
  end

  def parse_date(date_string)
    Date.parse(date_string) rescue nil
  end
end
```

**Error handling:**
- API timeout (60s): retry once, then fail
- API rate limit (429): fail with descriptive message, don't retry
- Invalid JSON in response: fail with "Failed to parse extraction results"
- PDF too large for API (>25MB base64): fail with "PDF is too large for processing"
- Missing API key: fail immediately with "ANTHROPIC_API_KEY not configured"

### 4.4 ParsePriceListJob

**New file:** `app/jobs/parse_price_list_job.rb`

```ruby
class ParsePriceListJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 30.seconds, attempts: 2

  def perform(inbound_price_list_id)
    price_list = InboundPriceList.find(inbound_price_list_id)
    return if price_list.parsed? # Idempotency guard

    PdfParsingService.new(price_list).call
  end
end
```

**Queue:** `default` (not `scraping` — this is an API call, not browser automation)
**Retries:** 2 attempts with 30s backoff (handles transient API errors)
**Idempotency:** Skip if already parsed (prevents duplicate parsing on job retry)

### 4.5 Routes (nested under email_suppliers)

```ruby
resources :email_suppliers, only: [:new, :create, :edit, :update, :destroy] do
  resources :price_lists, controller: 'inbound_price_lists', only: [:show] do
    collection { post :upload }
    member do
      get :status
      get :review   # PRD 4
      post :import  # PRD 4
    end
  end
end
```

---

## 5. Cost & Performance

### Claude API Costs
- **Input:** A typical supplier PDF (1-3 pages, ~120 products) is roughly 3,000-5,000 tokens as a document
- **Output:** ~120 products at ~50 tokens each = ~6,000 output tokens
- **Cost per parse (claude-sonnet-4-20250514):** ~$0.02-0.05 per PDF
- **At scale:** 1,000 suppliers sending weekly = 4,000 parses/month = ~$80-200/month

### Performance
- **Parse time:** 15-30 seconds for a typical PDF (API call dominates)
- **Base64 encoding:** A 1MB PDF becomes ~1.3MB base64 — well within API limits
- **Memory:** PDF is downloaded from Active Storage, encoded, and sent. Peak memory ~3x PDF size. For a 5MB PDF, that's ~15MB — acceptable for a background job.

---

## 6. Environment Variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `ANTHROPIC_API_KEY` | Yes (for parsing) | Claude API authentication |

This should be added to Railway environment variables for both web and worker services (the job runs on worker, but the key should be available on both for future use).

---

## 7. Edge Cases

| Scenario | Behavior |
|----------|----------|
| PDF is a scan/image (not text-based) | Claude's document understanding handles both text and image-based PDFs. No special handling needed. |
| PDF has no products (e.g., an invoice or delivery receipt) | Claude returns empty `products` array. Status set to `parsed` with `product_count: 0`. Review page shows "No products found in this PDF." |
| PDF is password-protected | Active Storage stores it fine, but Claude API will fail to read it. Error message: "PDF appears to be password-protected." |
| PDF is multi-page (10+ pages) | Claude handles multi-page documents natively. Increase `MAX_TOKENS` if needed. May take 30-60 seconds. |
| Chef uploads same PDF twice | Caught by `pdf_content_hash` dedup — redirected to existing parsed result. |
| Chef uploads PDF for wrong supplier | They can see the extracted data on review page and choose not to import. Upload a new PDF for the correct supplier. |
| API key not set | Fail immediately with clear error message. Don't save a `pending` record that will never be parsed. |
| Worker service not running | Job sits in Solid Queue until worker starts. Chef sees "Processing..." indefinitely. Status page shows a message after 5 minutes: "Processing is taking longer than expected. The background worker may need attention." |

---

## 8. Blue Ribbon Meats PDF — Expected Extraction

Based on the sample PDF (`03.08.2026.pdf`), the extraction should produce approximately:

```json
{
  "products": [
    { "sku": "200", "name": "#1 Tuna Loin", "price": 25.99, "pack_size": "per lb", "category": "Pelagic Ocean Fish" },
    { "sku": "201", "name": "Ahi Tuna #1 (2-4 oz pieces)", "price": 27.99, "pack_size": "per lb", "category": "Pelagic Ocean Fish" },
    ...
  ],
  "list_date": "2026-03-08",
  "supplier_name": "Blue Ribbon Meats & Seafood",
  "ordering_deadlines": "Order Monday by 10:00 AM for Wednesday ship"
}
```

~120 products across categories like Pelagic Ocean Fish, Ground Fish, Shellfish, etc.

---

## 9. Gem Dependencies

**No new gems required.** The Claude API is called via `Faraday` (already in Gemfile). Base64 encoding and JSON parsing are stdlib.

---

## 10. Out of Scope

- Review/import UI for parsed products → PRD 4
- Automatic re-parsing on failure (manual re-upload only for MVP)
- Action Mailbox email ingestion → Post-MVP
- PDF content dedup across emails → Post-MVP (MVP only deduplicates by hash within manual uploads)
- Batch upload of multiple PDFs → Not planned
