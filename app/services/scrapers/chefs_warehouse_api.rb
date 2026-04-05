# frozen_string_literal: true

module Scrapers
  # Direct HTTP API client for Chef's Warehouse.
  # Replaces browser-based scraping for most operations.
  #
  # CW's Vue.js SPA calls a REST API at chefswarehouse.com/web-api/*.
  # Authentication is cookie-based: POST /login/ sets session cookies
  # (.ASPXANONYMOUS, PROD_cwUserData, EPi:StateMarker, ARRAffinity).
  #
  # Browser is still needed for:
  #   - Initial login (to capture cookies) — unless API login works
  #   - Checkout/order placement (complex multi-step flow)
  #
  # Everything else (prices, order guides, search, cart) works via API.
  class ChefsWarehouseApi
    BASE_URL = 'https://www.chefswarehouse.com'

    attr_reader :credential, :logger

    def initialize(credential)
      @credential = credential
      @logger = Rails.logger
      @cookies = {}
      @http = nil
    end

    # ── Authentication ────────────────────────────────────────────

    # Try API-based login (no browser needed).
    # Returns true if login succeeded and cookies are set.
    def login
      logger.info '[CW-API] Attempting API login...'

      # First, hit the login page to get initial cookies (ASPX anonymous session)
      get('/')
      get('/login')

      response = post_json('/login/', {
        email: credential.username,
        password: credential.password,
        staySignedIn: true
      })

      if response && response['succeeded']
        logger.info '[CW-API] Login succeeded'
        save_session_cookies
        true
      else
        error = response&.dig('error') || 'Unknown error'
        logger.warn "[CW-API] Login failed: #{error}"
        false
      end
    end

    # Check if we have saved cookies (without making a request).
    def session_valid?
      raw = credential.session_data
      return false if raw.blank?

      session_data = raw.is_a?(String) ? (JSON.parse(raw) rescue {}) : (raw || {})
      stored_cookies = session_data['api_cookies']
      stored_cookies.is_a?(Hash) && stored_cookies.any?
    end

    # Restore session from saved credential data.
    # Returns true if the session is still valid.
    def restore_session
      raw = credential.session_data
      return false if raw.blank?

      session_data = raw.is_a?(String) ? (JSON.parse(raw) rescue {}) : (raw || {})

      stored_cookies = session_data['api_cookies']
      return false if stored_cookies.blank?

      # Restore cookies
      if stored_cookies.is_a?(Hash)
        @cookies = stored_cookies
      end

      # Verify session is still valid by hitting an authenticated endpoint
      response = post_json('/web-api/organization/list', {})
      if response.is_a?(Array) && response.any?
        logger.info '[CW-API] Session restored successfully'
        true
      else
        logger.info '[CW-API] Saved session is expired'
        @cookies = {}
        false
      end
    rescue StandardError => e
      logger.warn "[CW-API] Session restore failed: #{e.message}"
      @cookies = {}
      false
    end

    # Ensure we have a valid session (restore or login).
    def ensure_session!
      # Reload credential from DB — another job may have refreshed
      # the session while we were queued.
      credential.reload
      return if restore_session

      raise BaseScraper::AuthenticationError, 'CW API login failed' unless login
    end

    # Call this after an auth error to attempt recovery.
    def handle_auth_failure
      logger.info '[CW-API] Auth failure — attempting re-login...'
      credential.reload
      @cookies = {}
      return true if restore_session
      return true if login

      logger.warn '[CW-API] Re-login failed after auth error'
      false
    end

    # ── Categories ─────────────────────────────────────────────────

    # Fetch all product categories from the site navigation.
    # Returns array of { name:, path: } for top-level categories.
    def fetch_categories
      response = get_json('/HeaderData/')
      return [] unless response.is_a?(Hash)

      items = response.dig('categoryMenu', 'items') || []
      items.filter_map do |item|
        next unless item['href'].present?
        { name: item['text']&.strip, path: item['href'] }
      end
    end

    # ── Category Pages ─────────────────────────────────────────────

    # Fetch a category page to get its subcategory links.
    # Uses a separate unauthenticated request because the CMS returns
    # JSON for anonymous requests but HTML for authenticated ones.
    def fetch_category_page(category_path)
      require 'net/http'
      encoded_path = URI::DEFAULT_PARSER.escape(category_path.chomp('/'))
      uri = URI.parse("#{BASE_URL}#{encoded_path}/?expand=*&currentPageUrl=#{CGI.escape(category_path)}&tz=America%2FNew_York&t=#{Time.now.to_i}")
      req = Net::HTTP::Get.new(uri.request_uri)
      req['Accept'] = 'application/json'
      req['User-Agent'] = 'Mozilla/5.0'

      h = Net::HTTP.new(uri.host, uri.port)
      h.use_ssl = true
      h.open_timeout = 10
      h.read_timeout = 15
      resp = h.request(req)

      return nil unless resp.code == '200' && resp['content-type']&.include?('json')

      JSON.parse(resp.body)
    rescue StandardError => e
      logger.warn "[CW-API] fetch_category_page failed for #{category_path}: #{e.message}"
      nil
    end

    # ── Order Guides ──────────────────────────────────────────────

    # List all order guides for the current user.
    # Returns array of { name:, id:, type:, ... }
    def list_order_guides
      response = get_json('/web-api/order-guide/header-list')
      return [] unless response.is_a?(Array)

      response.map do |guide|
        {
          name: guide['text'],
          remote_id: guide['href']&.match(/id=(\d+)/)&.captures&.first,
          url: guide['href'],
          type: guide['href']&.include?('type=user') ? 'user' : 'standard'
        }
      end
    end

    # Fetch all items from an order guide.
    # Returns the full guide data including products.
    def fetch_order_guide(guide_id, type: 'customGroups', page: 1, page_size: 500)
      response = post_json(
        "/web-api/order-guide?id=#{guide_id}&type=#{type}&page=#{page}&pageSize=#{page_size}&searchTerm=",
        {}
      )
      return nil unless response.is_a?(Hash)

      # Extract products from ungrouped and grouped sections
      products = []

      # Ungrouped products
      ungrouped = response.dig('ungroupedProducts', 'lineItems') || []
      ungrouped.each { |item| products << parse_order_guide_item(item) }

      # Grouped products (custom groups)
      groups = response['groups'] || response['categories'] || []
      groups.each do |group|
        group_name = group['name']
        items = group['lineItems'] || group['products'] || []
        items.each do |item|
          parsed = parse_order_guide_item(item)
          parsed[:group] = group_name
          products << parsed
        end
      end

      {
        id: response['id'],
        name: response['name'],
        organization_id: response['organizationId'],
        type: response['type'],
        products: products
      }
    end

    # ── Pricing ───────────────────────────────────────────────────

    # Fetch live prices for an array of variant codes.
    # Each variant needs: code, uom, stockingType, vendorId, businessUnitId
    def fetch_prices(variants)
      return [] if variants.empty?

      # Batch in groups of 20 (like the SPA does)
      all_prices = []
      variants.each_slice(20) do |batch|
        payload = {
          variants: batch.map do |v|
            {
              code: v[:code],
              productKey: nil,
              productClassificationCode: nil,
              uom: v[:uom] || 'PC',
              checkAvailabilityFlag: true,
              chefItemFlag: false,
              bto: false,
              supermarket: false,
              specialOrderFlag: false,
              stockingType: v[:stocking_type] || 'P',
              vendorId: v[:vendor_id],
              businessUnitId: v[:business_unit_id] || '800001'
            }
          end,
          organizationId: nil
        }

        response = post_json('/web-api/product/prices', payload)
        next unless response.is_a?(Array)

        response.each do |price_data|
          all_prices << parse_price_response(price_data)
        end
      end

      all_prices
    end

    # Simplified price check for a list of SKUs (extracts variant info from order guide data).
    def fetch_prices_for_skus(sku_variant_map)
      variants = sku_variant_map.map do |_sku, info|
        {
          code: info[:variant_code],
          uom: info[:uom] || 'PC',
          stocking_type: info[:stocking_type] || 'P',
          vendor_id: info[:vendor_id],
          business_unit_id: info[:business_unit_id] || '800001'
        }
      end

      fetch_prices(variants)
    end

    # ── Product Search ────────────────────────────────────────────

    # Search products within a category.
    # category_path: e.g., '/products/oil-and-vinegar/oil/'
    # Uses the Episerver CMS search endpoint which requires minimal headers
    # (only content-type and user-timezone — extra headers cause 404).
    def search_category(category_path, page: 0, page_size: 50, page_token: '', facets: [])
      path = "#{category_path.chomp('/')}//search"

      # Must use minimal headers — the CMS rejects requests with Accept/Origin/Referer
      req = Net::HTTP::Post.new(path)
      req['content-type'] = 'application/json'
      req['user-timezone'] = 'America/New_York'
      req['Cookie'] = send(:cookie_header) unless @cookies.empty?
      req.body = {
        search: {
          page: page,
          pageSize: page_size,
          includeZStockingItems: false,
          pageToken: page_token,
          facets: facets,
          sortBy: nil,
          direction: nil
        }
      }.to_json

      response = http.request(req)
      extract_cookies(response)

      return { products: [], facets: [], total: 0 } unless response.code == '200'

      parsed = JSON.parse(response.body) rescue nil
      return { products: [], facets: [], total: 0 } unless parsed.is_a?(Hash)

      # Response uses 'results' key (not 'products')
      products = (parsed['results'] || parsed['products'] || []).map { |p| parse_search_product(p) }

      {
        products: products,
        facets: parsed['facets'] || [],
        total: parsed['total'] || parsed['totalCount'] || products.size,
        page_token: parsed['nextPageToken'] || parsed['pageToken'] || ''
      }
    end

    # ── Cart Operations ───────────────────────────────────────────

    # Get current cart contents.
    def get_cart
      get_json('/web-api/cart')
    end

    # Get or create a cart.
    def get_or_create_cart
      get_json('/web-api/cart/current-or-new')
    end

    # Add items to cart.
    # items: array of hashes with variant data from order guide.
    # Each item needs: code, metadata (with unitOfMeasure, stockingType, vendorId, etc.),
    # businessUnitId, quantity.
    def add_to_cart(items)
      payload = items.map do |item|
        meta = item[:metadata] || {
          productKey: nil,
          productClassificationCode: nil,
          chefItemFlag: false,
          bto: false,
          supermarket: false,
          stockingType: item[:stocking_type] || 'P',
          lineType: 'S',
          vendorId: item[:vendor_id],
          productionItem: false,
          orderCutoffOverride: nil
        }
        # Always apply the requested UOM — the pre-built order guide metadata
        # defaults to CS, but the user may have toggled to PC (piece ordering).
        meta = meta.merge('unitOfMeasure' => item[:uom] || 'CS') if meta.is_a?(Hash)

        {
          code: item[:code] || item[:variant_code],
          metadata: meta,
          isReserve: false,
          businessUnitId: item[:business_unit_id] || '800001',
          quantity: item[:quantity] || 1,
          cutInstructions1: nil,
          cutInstructions2: nil,
          customerFacingName: nil,
          sellByMultiple: item[:sell_by_multiple] || 1,
          addedFromLocation: 'OrderGuide',
          priceInfo: nil
        }
      end

      # CW expects a raw JSON array, not wrapped in an object
      response = request(:post, '/web-api/cart/add', body: payload.to_json)
      parse_response(response)
    end

    # Update a line item's quantity in the cart.
    # item: { id:, quantity:, code:, unitOfMeasure: }
    def update_cart_item(item)
      post_json('/web-api/cart/update-item', item)
    end

    # Remove an item from the cart by line item ID.
    def remove_cart_item(line_item_id)
      post_json("/web-api/cart/remove-item?id=#{line_item_id}", nil)
    end

    # Set the delivery date for the cart.
    def set_delivery_date(date_value)
      post_json('/web-api/cart/update/deliveryDate', { value: date_value })
    end

    # Set the PO number.
    def set_po_number(po_number)
      post_json('/web-api/cart/update/field', {
        name: 'cw_poNumber',
        value: po_number
      })
    end

    # Set delivery notes.
    def set_delivery_notes(notes)
      post_json('/web-api/cart/update/cartNotes', { value: notes })
    end

    # Refresh prices in the cart (before checkout).
    def refresh_cart_prices
      get_json('/web-api/cart/refresh-prices')
    end

    # Validate the cart before submission.
    def validate_cart
      get_json('/web-api/cart-validation')
    end

    # Get the cart summary (totals, delivery info).
    def cart_summary
      get_json('/web-api/cart/summary')
    end

    # Submit the cart (PLACE THE ORDER).
    # This is the final step — use with extreme caution.
    def submit_cart(dry_run: true)
      if dry_run
        logger.info '[CW-API] DRY RUN — not submitting cart'
        # Return cart summary without actually submitting
        return { dry_run: true, cart: get_cart, validation: validate_cart }
      end

      logger.warn '[CW-API] PLACING LIVE ORDER — submitting cart'
      response = request(:post, '/web-api/cart/submit')
      # Add timezone header like the SPA does
      parse_response(response)
    end

    # Delete/empty the cart.
    def delete_cart
      post_json('/web-api/cart/delete', {})
    end

    # ── Order History ─────────────────────────────────────────────

    def order_history_details
      get_json('/web-api/order-history/details')
    end

    # ── Organizations ─────────────────────────────────────────────

    def list_organizations
      post_json('/web-api/organization/list', {})
    end

    # ── Current User ──────────────────────────────────────────────

    def current_user
      post_json('/web-api/auth/current-user', {})
    end

    private

    # ── HTTP helpers ──────────────────────────────────────────────

    def get(path)
      request(:get, path)
    end

    def get_json(path)
      response = request(:get, path)
      parse_response(response)
    end

    def post_json(path, body)
      response = request(:post, path, body: body.to_json)
      parse_response(response)
    end

    # Persistent HTTP connection — CW requires session affinity
    # (ARRAffinity cookie binds to a specific backend server).
    def http
      @http ||= begin
        require 'net/http'
        uri = URI.parse(BASE_URL)
        h = Net::HTTP.new(uri.host, uri.port)
        h.use_ssl = true
        h.open_timeout = 15
        h.read_timeout = 60
        h.keep_alive_timeout = 120
        h.start
        h
      end
    end

    def request(method, path, body: nil)
      req = case method
            when :get
              Net::HTTP::Get.new(path)
            when :post
              Net::HTTP::Post.new(path)
            end

      # Set headers
      req['Content-Type'] = 'application/json'
      req['Accept'] = '*/*'
      req['User-Agent'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
      req['Origin'] = BASE_URL
      req['Referer'] = "#{BASE_URL}/"

      # Set cookies
      req['Cookie'] = cookie_header unless @cookies.empty?

      # Set body
      req.body = body if body

      response = http.request(req)

      # Capture Set-Cookie headers
      extract_cookies(response)

      response
    rescue Net::OpenTimeout, Net::ReadTimeout, IOError, Errno::ECONNRESET => e
      # Connection dropped — reset and retry once
      logger.warn "[CW-API] Connection error: #{e.class}, reconnecting..."
      @http&.finish rescue nil
      @http = nil
      raise
    rescue StandardError => e
      logger.error "[CW-API] HTTP #{method.upcase} #{path} failed: #{e.class}: #{e.message}"
      nil
    end

    def close
      @http&.finish rescue nil
      @http = nil
    end

    def parse_response(response)
      return nil unless response

      content_type = response['content-type'] || ''
      body = response.body

      if response.code.to_i == 302 || response.code.to_i == 301
        logger.warn "[CW-API] Redirect to: #{response['location']}"
        return nil
      end

      unless response.code.to_i.between?(200, 299)
        logger.warn "[CW-API] HTTP #{response.code}: #{body&.first(200)}"
        return nil
      end

      return nil if body.blank?

      if content_type.include?('json') || body.match?(/\A[\[{]/)
        JSON.parse(body)
      else
        body
      end
    rescue JSON::ParserError => e
      logger.warn "[CW-API] JSON parse error: #{e.message}"
      nil
    end

    def cookie_header
      @cookies.map { |k, v| "#{k}=#{v}" }.join('; ')
    end

    def extract_cookies(response)
      return unless response

      Array(response.get_fields('Set-Cookie')).each do |cookie_str|
        # Parse cookie name=value (ignore attributes)
        name_value = cookie_str.split(';').first
        next unless name_value

        name, value = name_value.split('=', 2)
        next unless name && value

        @cookies[name.strip] = value.strip
      end
    end

    def save_session_cookies
      existing = credential.session_data
      session_data = if existing.is_a?(String)
                       JSON.parse(existing) rescue {}
                     else
                       existing || {}
                     end
      session_data['api_cookies'] = @cookies
      credential.update!(session_data: session_data.to_json)
      logger.info "[CW-API] Saved #{@cookies.size} session cookies"
    end

    # ── Response parsers ──────────────────────────────────────────

    def parse_order_guide_item(item)
      variant = item['selectedVariant'] || item.dig('variants', 0) || {}
      metadata = variant['metadata'] || {}

      {
        name: item['name'],
        sku: item['productCode']&.sub(/\AJDE_/, ''),
        product_code: item['productCode'],
        pack_size: item['packSize'] || variant['packSize'],
        image_url: item['imageUrl'],
        in_stock: item['inStock'] != false,
        variant_code: variant['code'],
        uom: metadata['unitOfMeasure'] || variant['primaryUnitOfMeasureCode'],
        stocking_type: metadata['stockingType'] || variant['stockingType'],
        vendor_id: metadata['vendorId'],
        business_unit_id: variant['businessUnit'] || variant.dig('businessUnitModel', 'id'),
        stock_count: variant['inStock'],
        obsolete: item['obsolete'],
        last_ordered_date: item['lastOrderedDate'],
        sell_by_multiple: variant['sellByMultiple'] || 1,
        # Preserve raw metadata for cart/add API
        variant_metadata: metadata
      }
    end

    def parse_price_response(price_data)
      primary = price_data['primaryUnitPrice'] || {}
      secondary = price_data['secondaryUnitPrice'] || {}

      {
        variant_code: price_data['code'],
        pricing_uom: price_data['pricingUnitOfMeasure'],
        restricted: price_data['isRestrictedProduct'],
        primary_price: parse_dollar_amount(primary['price']),
        primary_uom: primary['unitOfMeasure'],
        secondary_price: parse_dollar_amount(secondary['price']),
        secondary_uom: secondary['unitOfMeasure'],
        unit_prices: (price_data['unitPrices'] || []).map do |up|
          {
            uom: up['unitOfMeasure'],
            price: parse_dollar_amount(up['price']),
            price_type: up['priceType'],
            pricing_uom_price: parse_dollar_amount(up['pricingUnitOfMeasurePrice'])
          }
        end
      }
    end

    def parse_search_product(product)
      variant = product.dig('variants', 0) || {}
      metadata = variant['metadata'] || {}

      # Category can be a hash (from order guide) or string (from search results)
      category = product['category']
      category_name = category.is_a?(Hash) ? category['text'] : category

      {
        name: product['description'] || product['name'],
        sku: product['sku'],
        brand: product['brand'],
        category: category_name,
        subcategory: product['subcategory'] || product['subsubcategory'],
        pack_size: variant['weight'] || variant['packSize'],
        variant_code: variant['code'],
        uom: metadata['unitOfMeasure'] || variant['primaryUnitOfMeasureCode'],
        stocking_type: metadata['stockingType'],
        vendor_id: metadata['vendorId'],
        business_unit_id: variant['businessUnit'] || variant.dig('businessUnitModel', 'id'),
        in_stock: variant['inStock'],
        is_frozen: product['isFrozen']
      }
    end

    def parse_dollar_amount(str)
      return nil if str.blank?

      str.to_s.gsub(/[^0-9.]/, '').to_f
    end
  end
end
