# frozen_string_literal: true

module Scrapers
  # Direct REST API client for US Foods.
  # Replaces browser-based scraping for most operations.
  #
  # US Foods uses a microservice API at panamax-api.ama.usfoods.com
  # with domain-driven endpoints (product-domain, price-domain, list-domain, etc.).
  #
  # Authentication:
  #   - Initial login via Azure AD B2C (browser-based, 2FA) yields an idToken
  #   - idToken is exchanged for a Panamax API accessToken + refreshToken
  #   - accessToken expires in 1 hour, refreshable via refreshToken
  #   - After initial 2FA login, session can be maintained indefinitely via refresh
  #
  # Browser is still needed for:
  #   - Initial 2FA login (to get the B2C idToken)
  #   - Order placement (sensitive, keep browser-based for safety)
  class UsFoodsApi
    API_BASE = 'https://panamax-api.ama.usfoods.com'

    SCOPES = 'usf-user usf-customer usf-list usf-order usf-product usf-alert usf-payment usf-inventory usf-partner usf-price'

    attr_reader :credential, :logger

    def initialize(credential)
      @credential = credential
      @logger = Rails.logger
      @access_token = nil
      @refresh_token = nil
      @token_expires_at = nil
      @auth_context = nil
    end

    # ── Authentication ────────────────────────────────────────────

    # Restore API tokens from saved credential session data.
    # Checks two sources:
    #   1. Our api_tokens (saved by previous API session)
    #   2. Browser localStorage (CapacitorStorage.auth-response from soft_refresh)
    def restore_session
      raw = credential.session_data
      return false if raw.blank?

      session_data = raw.is_a?(String) ? (JSON.parse(raw) rescue {}) : (raw || {})

      # Try our saved api_tokens first
      api_tokens = session_data['api_tokens']
      if api_tokens.is_a?(Hash) && api_tokens['access_token'].present?
        @access_token = api_tokens['access_token']
        @refresh_token = api_tokens['refresh_token']
        @token_expires_at = api_tokens['expires_at'] ? Time.parse(api_tokens['expires_at']) : nil
        @auth_context = api_tokens['auth_context']

        # If token is still valid, verify it
        unless token_expired?
          identity = get_identity
          if identity && identity['userId']
            logger.info "[USF-API] Session restored from api_tokens for user #{identity['userId']}"
            return true
          end
        end

        # Token expired but we have a refresh token — try refreshing via API
        if @refresh_token.present?
          logger.info '[USF-API] Token expired, attempting API refresh...'
          return true if refresh_access_token
        end
      end

      # Fall back to browser localStorage (populated by soft_refresh)
      ls = session_data['local_storage'] || {}
      auth_response_str = ls['CapacitorStorage.auth-response']
      if auth_response_str.present?
        auth_response = JSON.parse(auth_response_str) rescue nil
        if auth_response && auth_response['accessToken'].present?
          @access_token = auth_response['accessToken']
          @refresh_token = auth_response['refreshToken']
          @token_expires_at = Time.current + 3600 # Assume 1 hour from now
          auth_ctx_str = ls['CapacitorStorage.auth-context']
          auth_ctx = JSON.parse(auth_ctx_str) rescue {}
          @auth_context = {
            'division_number' => auth_ctx['divisionNumber'],
            'customer_number' => auth_ctx['customerNumber'],
            'department_number' => auth_ctx['departmentNumber']
          }

          identity = get_identity
          if identity && identity['userId']
            logger.info "[USF-API] Session restored from browser localStorage for user #{identity['userId']}"
            save_session_tokens
            return true
          end
        end
      end

      logger.info '[USF-API] No valid session found'
      clear_tokens
      false
    rescue StandardError => e
      logger.warn "[USF-API] Session restore failed: #{e.message}"
      clear_tokens
      false
    end

    # Exchange a B2C idToken (from browser login) for API tokens.
    # Called after the browser-based 2FA login captures the idToken.
    def authenticate_with_id_token(id_token)
      response = post_json('/auth-api/v1/oauth/token', {
        grantType: 'b2c',
        scopes: SCOPES,
        platform: 'DESKTOP',
        authContext: { divisionNumber: 0, customerNumber: 0, departmentNumber: 0 },
        refreshToken: '',
        idToken: id_token
      })

      if response && response['accessToken']
        store_tokens(response)
        save_session_tokens
        logger.info "[USF-API] Authenticated via B2C idToken, user #{response['userId']}"
        true
      else
        logger.warn "[USF-API] B2C token exchange failed (status: #{response['statusCode'] || 'unknown'})"
        false
      end
    end

    # Refresh the access token using the refresh token.
    # US Foods uses grantType "refreshToken" (camelCase) and consumer-id "ecomr4".
    def refresh_access_token
      return false unless @refresh_token

      logger.info '[USF-API] Refreshing access token...'

      # Must use ecomr4 consumer-id for refresh (different from regular API calls)
      req = Net::HTTP::Post.new('/auth-api/v1/oauth/token')
      req['Content-Type'] = 'application/json'
      req['Accept'] = 'application/json'
      req['consumer-id'] = 'ecomr4'
      req['correlation-id'] = "ecomr4-#{SecureRandom.uuid}"
      req['transaction-id'] = "#{(Time.current.to_f * 1000).to_i}"
      req['trace-context'] = 'login'
      req.body = {
        grantType: 'refreshToken',
        scopes: SCOPES,
        platform: 'DESKTOP',
        authContext: @auth_context ? {
          divisionNumber: @auth_context['division_number'],
          customerNumber: @auth_context['customer_number'],
          departmentNumber: @auth_context['department_number']
        } : { divisionNumber: 0, customerNumber: 0, departmentNumber: 0 },
        refreshToken: @refresh_token,
        idToken: ''
      }.to_json

      resp = http.request(req)
      response = parse_response(resp)

      if response && response['accessToken']
        store_tokens(response)
        save_session_tokens
        logger.info '[USF-API] Token refreshed successfully'
        true
      else
        logger.warn "[USF-API] Token refresh failed (status: #{response['statusCode'] || 'unknown'})"
        clear_tokens
        false
      end
    end

    # Ensure we have a valid session (restore, refresh, or fail).
    def ensure_session!
      return if @access_token && !token_expired?

      # Reload credential from DB — another job (e.g. RefreshSessionJob)
      # may have refreshed the token while we were queued.
      credential.reload
      return if restore_session

      raise BaseScraper::AuthenticationError, 'USF API session expired — 2FA login required'
    end

    # Call this after a 401 to attempt recovery before giving up.
    def handle_auth_failure
      logger.info '[USF-API] Got 401 — attempting token refresh...'
      credential.reload
      @access_token = nil # Force restore_session to re-read from DB
      return true if restore_session

      logger.warn '[USF-API] Token refresh failed after 401'
      false
    end

    def session_valid?
      @access_token.present? && !token_expired?
    end

    # ── User / Customer ───────────────────────────────────────────

    def get_identity
      get_json('/user-domain-api/v1/identity')
    end

    def get_customers
      get_json('/customer-domain-api/v1/customers')
    end

    def get_divisions
      get_json('/customer-domain-api/v1/divisions')
    end

    # ── Order Guides & Lists ──────────────────────────────────────

    def list_order_guides
      get_json('/list-domain-api/v1/orderGuides')
    end

    def get_order_guide_items
      get_json('/list-domain-api/v1/orderGuideItems')
    end

    def get_order_guide_groups
      get_json('/list-domain-api/v1/orderGuideGroups')
    end

    def list_shopping_lists
      get_json('/list-domain-api/v1/lists?watermark=1995-01-01T00:00:00.000Z')
    end

    def get_shopping_list_items
      get_json('/list-domain-api/v1/listItems?watermark=1995-01-01T00:00:00.000Z')
    end

    def get_recent_purchases
      get_json('/list-domain-api/v1/recentPurchase?watermark=null')
    end

    # ── Products ──────────────────────────────────────────────────

    # Fetch products by product numbers (batch).
    # product_numbers: array of integers
    def fetch_products(product_numbers)
      return [] if product_numbers.empty?

      all_items = []
      product_numbers.each_slice(50) do |batch|
        response = post_json('/product-domain-api/v2/products', {
          productNumbers: batch
        })
        items = response&.dig('items') || []
        all_items.concat(items)
      end
      all_items
    end

    # Fetch detailed product info (with claims, nutrition, etc.).
    def fetch_product_details(product_numbers)
      return [] if product_numbers.empty?

      all_items = []
      product_numbers.each_slice(20) do |batch|
        response = post_json('/product-domain-api/v1/productdetail', batch)
        items = response&.dig('items') || (response.is_a?(Array) ? response : [])
        all_items.concat(items)
      end
      all_items
    end

    # Browse product categories.
    def browse_categories
      get_json('/product-domain-api/v1/browse')
    end

    # Get full category taxonomy.
    def get_taxonomy
      get_json('/search-domain-api/v1/taxonomy')
    end

    # Get new products.
    def get_new_products
      get_json('/product-domain-api/v1/products/new-products')
    end

    # ── Pricing ───────────────────────────────────────────────────

    # Fetch prices for product numbers.
    def fetch_prices(product_numbers, feature: '/desktop/home')
      return {} if product_numbers.empty?

      all_prices = {}
      product_numbers.each_slice(50) do |batch|
        response = post_json('/price-domain-api/v1/pricing', {
          productNumbers: batch,
          feature: feature
        })

        product_list = response&.dig('messageDetail', 'productList') || []
        product_list.each do |item|
          pn = item['productNumber'].to_i
          all_prices[pn] = {
            case_price: item['unitPrice']&.to_f,
            split_price: item['splitPrice']&.to_f,
            price_uom: item['priceUom'],
            catch_weight: item['catchWeightFlag'],
            effective_date: response&.dig('messageDetail', 'priceEffectiveDate')
          }
        end
      end
      all_prices
    end

    # ── Orders ────────────────────────────────────────────────────

    def get_orders
      get_json('/order-domain-api/v1/orders')
    end

    def get_recent_orders
      get_json('/order-domain-api/v1/recentorders')
    end

    def get_next_delivery_date
      get_json('/order-request-reply-domain-api/v1/nextDeliveryDate')
    end

    # ── Cart / Order Operations ────────────────────────────────

    # Get or create an order for the given delivery date.
    # Returns the order object (with orderId, items, etc.)
    def get_or_create_order(delivery_date = nil)
      orders = get_orders
      orders = [orders] if orders.is_a?(Hash) # API sometimes returns single order
      return nil unless orders.is_a?(Array)

      # Filter to only Hash elements — API can include non-Hash entries
      orders = orders.select { |o| o.is_a?(Hash) }

      delivery_date_str = if delivery_date
                            delivery_date.is_a?(String) ? delivery_date : delivery_date.strftime('%Y-%m-%dT00:00:00.000Z')
                          end

      # Find existing IN_PROGRESS order, preferring matching delivery date
      if delivery_date_str
        existing = orders.find do |o|
          o['orderStatus'] == 'IN_PROGRESS' && o['requestedDeliveryDate'] == delivery_date_str
        end
        return existing if existing
      end

      # Fall back to any IN_PROGRESS order
      existing = orders.find { |o| o['orderStatus'] == 'IN_PROGRESS' }
      if existing
        # Update its delivery date if needed
        if delivery_date_str && existing['requestedDeliveryDate'] != delivery_date_str
          existing['requestedDeliveryDate'] = delivery_date_str
          existing['confirmedDeliveryDate'] = delivery_date_str
          existing['updateDtm'] = Time.current.iso8601(3)
          result = put_json('/order-domain-api/v1/orders', existing)
          result = normalize_order_response(result, existing['orderId']) if result.is_a?(Array)
          return result.is_a?(Hash) ? result : existing
        end
        return existing
      end

      # No existing order — create one via PUT with minimal payload
      # (matches the exact format the USF Ionic SPA sends)
      logger.info '[USF-API] No existing order found, creating new order via API'
      delivery_date_str ||= begin
        ndd = get_next_delivery_date
        ndd&.dig('nextDeliveryDate') || Date.tomorrow.strftime('%Y-%m-%dT00:00:00.000Z')
      end

      new_order = {
        'requestedDeliveryDate' => delivery_date_str,
        'confirmedDeliveryDate' => delivery_date_str,
        'purchaseOrderNumber' => '',
        'orderItems' => [],
        'decomposeFlag' => true
      }

      result = put_json('/order-domain-api/v1/orders', new_order)
      if result
        # API may return a single order hash or an array — normalize
        order_obj = result.is_a?(Array) ? result.find { |o| o['orderStatus'] == 'IN_PROGRESS' } || result.first : result
        order_id = order_obj&.dig('orderId')
        logger.info "[USF-API] Created order #{order_id}"
        # Fetch the full order object with server-generated fields
        if order_id
          sleep 0.5
          full_orders = get_orders
          if full_orders.is_a?(Array)
            full_order = full_orders.find { |o| o['orderId'] == order_id }
            return full_order if full_order
          end
        end
        order_obj || result
      else
        logger.error '[USF-API] Failed to create order'
        raise ScrapingError, 'Could not create order on US Foods'
      end
    end

    # Add items to an existing order. Takes the current order object and
    # appends new order items, then PUTs the updated order back.
    # Field names match USF's Ionic SPA exactly: orderItems, unitsOrdered, sequence, etc.
    def add_items_to_order(order, items)
      order_items = order['orderItems'] || []
      next_sequence = (order_items.map { |oi| oi['sequence'].to_i }.max || 0) + 1

      user_id = @auth_context.is_a?(Hash) ? @auth_context['user_id']&.to_s : nil
      now = Time.current.iso8601(3)

      items.each_with_index do |item, idx|
        order_items << {
          'eachesOrdered' => 0,
          'sequence' => next_sequence + idx,
          'unitsOrdered' => item[:quantity].to_i,
          'productNumber' => item[:sku].to_i,
          'purchasedFromVendor' => item[:vendor_id].to_i,
          'specialVendor' => false,
          'addDtm' => now,
          'addOrderSource' => 'MO',
          'addUserId' => user_id,
          'addUserRole' => 'CUST',
          'updateDtm' => now,
          'updateOrderSource' => 'MO',
          'updateUserId' => user_id,
          'updateUserRole' => 'CUST'
        }
      end

      order['orderItems'] = order_items
      order['updateDtm'] = now

      result = put_json('/order-domain-api/v1/orders', order)
      # Normalize response — may be array, hash, or unexpected type (String on reuse)
      normalized = if result.is_a?(Array)
                     result.find { |o| o.is_a?(Hash) && o['orderId'] == order['orderId'] } || result.first
                   elsif result.is_a?(Hash)
                     result
                   end
      # Fall back to the locally-modified order if API returned non-Hash
      normalized.is_a?(Hash) ? normalized : order
    end

    # Remove items from an order by product number
    def remove_items_from_order(order, product_numbers)
      product_numbers = Array(product_numbers).map(&:to_i)
      order_items = order['orderItems'] || []
      order['orderItems'] = order_items.reject { |oi| product_numbers.include?(oi['productNumber'].to_i) }
      order['updateDtm'] = Time.current.iso8601(3)

      result = put_json('/order-domain-api/v1/orders', order)
      normalize_order_response(result, order['orderId'])
    end

    # Clear all items from the order
    def clear_order(order)
      order['orderItems'] = []
      order['totalUnits'] = 0
      order['totalEaches'] = 0
      order['updateDtm'] = Time.current.iso8601(3)

      result = put_json('/order-domain-api/v1/orders', order)
      normalize_order_response(result, order['orderId'])
    end

    # Submit the order for processing via USF's order-submission-domain-api.
    #
    # USF's Ionic SPA POSTs the full order to a SEPARATE submission service
    # (order-submission-domain-api), NOT a PUT to the order-domain-api.
    # The submission service assigns a real order number (e.g., 408719)
    # and routes the order for fulfillment.
    #
    # - IN_PROGRESS orders → /submitIpOrder
    # - Editing already-submitted orders → /updateSubmittedOrder
    def submit_order(order)
      status = order['orderStatus']
      endpoint = if status == 'IN_PROGRESS' || order['tandemOrderNumber'].to_i == 0
                   '/order-submission-domain-api/v1/submitIpOrder'
                 else
                   '/order-submission-domain-api/v1/updateSubmittedOrder'
                 end

      logger.info "[USF-API] Submitting order via #{endpoint} (status=#{status}, orderId=#{order['orderId']})"

      result = post_json(endpoint, order)

      unless result
        logger.error '[USF-API] Order submission returned nil'
        return nil
      end

      # The submission API returns the submitted order (may be array or hash)
      submitted = result.is_a?(Array) ? result.first : result

      if submitted.is_a?(Hash)
        order_num = submitted['tandemOrderNumber'] || submitted['orderId']
        new_status = submitted['orderStatus']
        logger.info "[USF-API] Order submitted: number=#{order_num}, status=#{new_status}"
      end

      submitted
    end

    # Cancel an order
    def cancel_order(order)
      order['orderStatus'] = 'CANCELLED'
      order['updateDtm'] = Time.current.iso8601(3)

      result = put_json('/order-domain-api/v1/orders', order)
      normalize_order_response(result, order['orderId'])
    end

    private

    # USF order API always returns an array of all orders.
    # Extract the specific order we care about.
    def normalize_order_response(result, order_id = nil)
      return result if result.is_a?(Hash)
      return result unless result.is_a?(Array)

      hash_orders = result.select { |o| o.is_a?(Hash) }
      return result.first if hash_orders.empty?

      if order_id
        hash_orders.find { |o| o['orderId'] == order_id } || hash_orders.first
      else
        hash_orders.find { |o| o['orderStatus'] == 'IN_PROGRESS' } || hash_orders.first
      end
    end

    public

    # ── Search (Coveo) ──────────────────────────────────────────

    def get_search_token
      response = get_json('/auth-api/v1/search/token')
      response&.dig('coveoToken')
    end

    COVEO_ORG = 'usfoodsproduction10upnbvk4'
    COVEO_FIELDS = %w[ec_brand ec_skus ec_category sales_pack_size_long permanentid product_status].freeze

    # Search Coveo for product numbers, optionally filtered by category.
    # Returns array of product number integers.
    # Coveo has a 5000 result limit per query — use category filters for large catalogs.
    def search_product_numbers(category: nil, page_size: 500, max_results: 5000, filter: nil)
      token = get_search_token
      return [] unless token

      coveo_http = Net::HTTP.new("#{COVEO_ORG}.org.coveo.com", 443)
      coveo_http.use_ssl = true
      coveo_http.open_timeout = 10
      coveo_http.read_timeout = 30

      all_numbers = []
      offset = 0

      loop do
        req = Net::HTTP::Post.new('/rest/search/v2')
        req['Content-Type'] = 'application/json'
        req['Authorization'] = "Bearer #{token}"

        body = {
          q: '',
          numberOfResults: [page_size, max_results - offset].min,
          firstResult: offset,
          fieldsToInclude: COVEO_FIELDS
        }
        aq_parts = []
        aq_parts << "@ec_category=\"#{category}\"" if category.present?
        aq_parts << filter if filter.present?
        body[:aq] = aq_parts.join(' ') if aq_parts.any?
        req.body = body.to_json

        resp = coveo_http.request(req)
        break unless resp.code == '200'

        data = JSON.parse(resp.body)
        results = data['results'] || []
        break if results.empty?

        results.each do |r|
          pn = r.dig('raw', 'permanentid') || r['uri']&.match(%r{products/(\d+)})&.captures&.first
          all_numbers << pn.to_i if pn
        end

        offset += results.size
        break if offset >= max_results
        break if offset >= (data['totalCount'] || 0)
      end

      coveo_http.finish rescue nil
      all_numbers.uniq
    end

    private

    # ── Token management ──────────────────────────────────────────

    def token_expired?
      return true unless @token_expires_at

      Time.current >= @token_expires_at
    end

    def store_tokens(response)
      @access_token = response['accessToken']
      @refresh_token = response['refreshToken'] if response['refreshToken'].present?
      @token_expires_at = Time.current + (response['expiresIn'] || 3600).to_i.seconds
      @auth_context = {
        'division_number' => response['divisionNumber'],
        'customer_number' => response['customerNumber'],
        'department_number' => response['departmentNumber'],
        'user_id' => response['userId']
      }
    end

    def clear_tokens
      @access_token = nil
      @refresh_token = nil
      @token_expires_at = nil
      @auth_context = nil
    end

    def save_session_tokens
      raw = credential.session_data
      session_data = if raw.is_a?(String)
                       JSON.parse(raw) rescue {}
                     else
                       raw || {}
                     end

      session_data['api_tokens'] = {
        'access_token' => @access_token,
        'refresh_token' => @refresh_token,
        'expires_at' => @token_expires_at&.iso8601,
        'auth_context' => @auth_context
      }

      credential.update!(session_data: session_data.to_json)
      logger.info '[USF-API] Saved API tokens to credential'
    end

    # ── HTTP helpers ──────────────────────────────────────────────

    def get_json(path)
      response = request(:get, path)
      parse_response(response)
    end

    def post_json(path, body)
      response = request(:post, path, body: body.to_json)
      parse_response(response)
    end

    def put_json(path, body)
      response = request(:put, path, body: body.to_json)
      parse_response(response)
    end

    def http
      @http ||= begin
        require 'net/http'
        uri = URI.parse(API_BASE)
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
            when :put
              Net::HTTP::Put.new(path)
            end

      req['Content-Type'] = 'application/json'
      req['Accept'] = 'application/json'
      req['Authorization'] = "Bearer #{@access_token}" if @access_token
      req['consumer-id'] = 'ecom'
      req['correlation-id'] = "ecom-#{SecureRandom.uuid}"
      req['transaction-id'] = "#{(Time.current.to_f * 1000).to_i}"
      req.body = body if body

      response = http.request(req)
      response
    rescue Net::OpenTimeout, Net::ReadTimeout, IOError, Errno::ECONNRESET => e
      logger.warn "[USF-API] Connection error: #{e.class}, reconnecting..."
      @http&.finish rescue nil
      @http = nil
      raise
    rescue StandardError => e
      logger.error "[USF-API] HTTP #{method.upcase} #{path} failed: #{e.class}: #{e.message}"
      nil
    end

    def parse_response(response)
      return nil unless response

      unless response.code.to_i.between?(200, 299)
        logger.warn "[USF-API] HTTP #{response.code}: #{response.body&.first(200)}"
        return nil
      end

      body = response.body
      return nil if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError => e
      logger.warn "[USF-API] JSON parse error: #{e.message}"
      nil
    end

    public

    def close
      @http&.finish rescue nil
      @http = nil
    end
  end
end
