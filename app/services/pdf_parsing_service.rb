# Parses a supplier PDF price list using the Groq API (Llama).
# Extracts text from the PDF, then uses AI to structure the data.
#
# Usage:
#   service = PdfParsingService.new(inbound_price_list)
#   result = service.call
#   # => { success: true, product_count: 120 }
#
class PdfParsingService
  GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions'.freeze
  MODEL = 'llama-3.3-70b-versatile'.freeze
  MAX_TOKENS = 8192
  TIMEOUT = 120 # seconds

  EXTRACTION_PROMPT = <<~PROMPT.freeze
    You are a food service product data extractor. Analyze this supplier price list text
    and extract ALL products into structured JSON.

    Return ONLY valid JSON with this exact structure (no markdown, no code fences, no explanation):
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
    - If no date is visible, set list_date to null
    - Return ONLY the JSON object, nothing else
  PROMPT

  attr_reader :price_list

  def initialize(inbound_price_list)
    @price_list = inbound_price_list
    @api_key = ENV['GROQ_API_KEY'] || Rails.application.credentials.dig(:groq, :api_key)
  end

  def call
    raise "GROQ_API_KEY not configured" if @api_key.blank?

    price_list.update!(status: 'parsing')

    pdf_text = extract_pdf_text
    raise "Could not extract text from PDF — the file may be image-only or corrupted" if pdf_text.blank?

    Rails.logger.info "[PdfParsing] Extracted #{pdf_text.length} chars from #{price_list.pdf_file_name}"

    response = call_groq_api(pdf_text)
    parsed = extract_json(response)

    price_list.update!(
      status: 'parsed',
      raw_products_json: parsed,
      product_count: parsed['products']&.size || 0,
      list_date: parse_date(parsed['list_date']),
      error_message: nil
    )

    Rails.logger.info "[PdfParsing] Successfully parsed #{price_list.product_count} products from #{price_list.pdf_file_name}"

    { success: true, product_count: price_list.product_count }
  rescue => e
    Rails.logger.error "[PdfParsing] Failed to parse price list #{price_list.id}: #{e.class}: #{e.message}"
    Sentry.capture_exception(e, extra: { price_list_id: price_list.id })

    price_list.update!(
      status: 'failed',
      error_message: "#{e.class}: #{e.message}"
    )

    { success: false, error: e.message }
  end

  private

  def extract_pdf_text
    pdf_binary = price_list.pdf.download
    reader = PDF::Reader.new(StringIO.new(pdf_binary))
    reader.pages.map(&:text).join("\n\n--- Page Break ---\n\n")
  end

  def call_groq_api(pdf_text)
    conn = Faraday.new(url: GROQ_API_URL) do |f|
      f.options.timeout = TIMEOUT
      f.options.open_timeout = 10
    end

    response = conn.post do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{@api_key}"
      req.body = {
        model: MODEL,
        max_tokens: MAX_TOKENS,
        temperature: 0.1,
        messages: [
          {
            role: 'system',
            content: 'You extract structured product data from price lists. Return only valid JSON.'
          },
          {
            role: 'user',
            content: "#{EXTRACTION_PROMPT}\n\n---\n\nHere is the price list text:\n\n#{pdf_text}"
          }
        ]
      }.to_json
    end

    unless response.success?
      body = JSON.parse(response.body) rescue {}
      error_msg = body.dig('error', 'message') || "HTTP #{response.status}"
      raise "Groq API error: #{error_msg}"
    end

    JSON.parse(response.body)
  end

  def extract_json(api_response)
    text = api_response.dig('choices', 0, 'message', 'content')
    raise "No text content in API response" if text.blank?

    # Handle potential markdown code fences
    json_text = text.gsub(/\A```(?:json)?\s*\n?/, '').gsub(/\n?```\s*\z/, '').strip

    parsed = JSON.parse(json_text)

    # Validate expected structure
    raise "Missing 'products' key in response" unless parsed.key?('products')
    raise "'products' is not an array" unless parsed['products'].is_a?(Array)

    parsed
  end

  def parse_date(date_string)
    return nil if date_string.blank?
    Date.parse(date_string)
  rescue ArgumentError
    nil
  end
end
