# frozen_string_literal: true

module Scrapers
  # Direct API client for Performance Foodservice (CustomerFirst platform).
  #
  # CustomerFirst's middleware exposes RPC-style routes:
  #   https://apps-zz-cusfst-mw-p-eus01.azurewebsites.net/api/{Service}/V1/{Method}
  #
  # Authentication:
  #   - PerformanceScraper logs in via Azure AD B2C (email + password) and saves
  #     the SPA's MSAL.js cache (localStorage + sessionStorage) into session_data
  #   - MSAL cache entries hold the API access token (key contains "-accesstoken-",
  #     value JSON has "secret", "target" = scopes, "expiresOn" = unix seconds)
  #     and a refresh token (key contains "-refreshtoken-")
  #   - Access tokens are refreshed directly against the B2C token endpoint
  #     (public client + refresh_token grant), so no browser is needed until
  #     the refresh token itself dies
  #
  # Quirk: the middleware returns HTTP 203 (not 401) when unauthenticated —
  # treat 203 as an auth failure, never as success.
  class PerformanceApi
    API_BASE = 'https://apps-zz-cusfst-mw-p-eus01.azurewebsites.net'
    API_SCOPE_HOST = 'customer-first-site-api'
    CLIENT_ID = 'c68e7fae-80a1-42db-bd89-3fb37d1224a2'
    TOKEN_ENDPOINT = 'https://pfgcustomerfirst.b2clogin.com/pfgcustomerfirst.onmicrosoft.com/b2c_1a_signup_signin/oauth2/v2.0/token'

    # SearchProductCatalog requires the full filter object even when empty.
    EMPTY_ADVANCE_FILTER = {
      'Badges' => [], 'CategoryIds' => [], 'Brands' => [], 'StorageTypes' => [],
      'StateOfOriginAbbreviations' => [], 'DeliveryOptions' => {}, 'Nutritional' => {}, 'Manufacturers' => []
    }.freeze

    PRICE_BATCH_SIZE = 50

    # "No active order" sentinel. Catalog/list/price calls require an
    # OrderEntryHeaderId; when the account has no open draft (the normal resting
    # state — drafts expire) GetActiveOrder returns none, and passing nil/omitted
    # makes the middleware 400 with "Product Catalog page is not available". The
    # all-zeros GUID is what the SPA itself sends in that state, and it works.
    NO_ACTIVE_ORDER = '00000000-0000-0000-0000-000000000000'

    class ApiError < StandardError; end
    class AuthError < ApiError; end

    attr_reader :credential, :logger

    def initialize(credential)
      @credential = credential
      @logger = Rails.logger
      @access_token = nil
      @refresh_token = nil
      @token_expires_at = nil
      @token_scopes = nil
    end

    # Load API tokens from the MSAL cache the scraper persisted.
    # Returns true when a usable (or refreshable) token is found.
    def restore_session
      raw = credential.session_data
      return false if raw.blank?

      data = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end
      storage = (data['local_storage'] || {}).merge(data['session_storage'] || {})

      access_entry = msal_entry(storage, '-accesstoken-') { |v| v['target'].to_s.include?(API_SCOPE_HOST) }
      refresh_entry = msal_entry(storage, '-refreshtoken-')

      if access_entry
        @access_token = access_entry['secret']
        @token_scopes = access_entry['target']
        @token_expires_at = access_entry['expiresOn'].to_i.positive? ? Time.zone.at(access_entry['expiresOn'].to_i) : nil
      end
      @refresh_token = refresh_entry && refresh_entry['secret']

      if @access_token.present? && !token_expired?
        logger.info "[Performance-API] Session restored from MSAL cache (expires #{@token_expires_at})"
        return true
      end

      if @refresh_token.present?
        logger.info '[Performance-API] Access token missing/expired, refreshing via B2C...'
        return true if refresh_access_token
      end

      logger.info '[Performance-API] No usable API token in session data'
      false
    rescue StandardError => e
      logger.warn "[Performance-API] Session restore failed: #{e.class}: #{e.message}"
      false
    end

    # Public-client refresh against the B2C token endpoint.
    def refresh_access_token
      return false if @refresh_token.blank?

      scope = @token_scopes.presence || "openid offline_access https://pfgcustomerfirst.onmicrosoft.com/api/#{API_SCOPE_HOST}"
      uri = URI(TOKEN_ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri.request_uri)
      req.set_form_data(
        'client_id' => CLIENT_ID,
        'grant_type' => 'refresh_token',
        'refresh_token' => @refresh_token,
        'scope' => scope
      )
      res = http.request(req)

      unless res.is_a?(Net::HTTPSuccess)
        logger.warn "[Performance-API] Token refresh failed: HTTP #{res.code} #{res.body.to_s.truncate(300)}"
        return false
      end

      payload = JSON.parse(res.body)
      @access_token = payload['access_token']
      @refresh_token = payload['refresh_token'] if payload['refresh_token'].present?
      @token_expires_at = Time.current + payload['expires_in'].to_i
      logger.info "[Performance-API] Access token refreshed (expires #{@token_expires_at})"
      @access_token.present?
    rescue StandardError => e
      logger.warn "[Performance-API] Token refresh error: #{e.class}: #{e.message}"
      false
    end

    def token_expired?
      @token_expires_at.nil? || @token_expires_at <= Time.current + 60
    end

    # Decoded claims from the current access token (identity sanity check
    # without hitting the API). Returns {} when no token is loaded.
    def token_claims
      return {} if @access_token.blank?

      payload = @access_token.split('.')[1]
      return {} if payload.blank?

      JSON.parse(Base64.urlsafe_decode64(payload + '=' * (-payload.length % 4)))
    rescue StandardError
      {}
    end

    # Restore the API session or raise. Mirrors UsFoodsApi#ensure_session!.
    def ensure_session!
      return true if @access_token.present? && !token_expired?
      return true if restore_session

      raise AuthError, 'Performance API session expired — re-login required'
    end

    # Per-account context needed by nearly every catalog/order call:
    # customer GUID, operation company, business unit, active order id, and the
    # delivery date prices are quoted against. Derived from GetCurrentUserSite
    # (UserCustomers) + GetActiveOrder. Memoized for the life of this client.
    def account_context
      @account_context ||= begin
        site = call('Site', 'GetCurrentUserSite', nil, http_method: :get)
        customers = site&.dig('ResultObject', 'UserCustomers') || []
        customer = customers.first
        raise ApiError, 'No UserCustomers on account — cannot derive customer context' if customer.nil?

        customer_id = customer['CustomerId']
        ctx = {
          customer_id: customer_id,
          operation_company_number: customer['OperationCompanyNumber'].to_s,
          business_unit_key: customer['BusinessUnitKey'] || 0,
          customer_number: customer['CustomerNumber'],
          customer_name: customer['CustomerName']
        }

        active = call('OrderEntryHeader', 'GetActiveOrder', nil, http_method: :get,
                                                             query: { 'CustomerId' => customer_id })
        # Fall back to the no-active-order sentinel so read paths (catalog/list/
        # price) work whether or not a draft is open. Write paths (add_to_cart)
        # must create a real draft first — see active_order_id_for_write!.
        ctx[:order_entry_header_id] = active&.dig('ResultObject', 'OrderEntryHeaderId').presence || NO_ACTIVE_ORDER
        ctx[:delivery_date] = active&.dig('ResultObject', 'DeliveryDate')
        ctx
      end
    end

    # One page of catalog search results for a term. Returns the ResultObject
    # hash ({ CatalogProducts:, NumberOfPages:, CurrentPageNumber:, ... }) or nil.
    # Prices are NOT included (LoadPricing:false) — call fetch_prices separately.
    def search_catalog(query_text, page: 0, page_size: 25)
      ctx = account_context
      body = {
        'BusinessUnitKey' => ctx[:business_unit_key],
        'OperationCompanyNumber' => ctx[:operation_company_number],
        'CustomerId' => ctx[:customer_id],
        'DeliveryDate' => ctx[:delivery_date],
        'CurrentPageNumber' => page,
        'PageSize' => page_size,
        'QueryText' => query_text,
        'Skip' => page * page_size,
        'OrderEntryHeaderId' => ctx[:order_entry_header_id],
        'LoadPricing' => false,
        'AdvanceFilter' => EMPTY_ADVANCE_FILTER
      }
      res = call('ProductCatalog', 'SearchProductCatalog', body)
      unless res && res['IsSuccess']
        raise ApiError, "SearchProductCatalog failed for '#{query_text}': #{res && res['ErrorMessages']}"
      end

      res['ResultObject']
    end

    # Look up a single catalog product by its SKU (== ProductKey). Returns the
    # CatalogProduct hash (with UOM/catch-weight fields) or nil. Used by
    # scrape_prices, which needs the product detail to compute the case price.
    def product_by_sku(sku)
      ro = search_catalog(sku.to_s, page: 0, page_size: 10)
      (ro && ro['CatalogProducts'] || []).find { |p| p['ProductNumber'].to_s == sku.to_s }
    end

    # Customer-specific case prices for a set of ProductKeys. Batches internally.
    # Returns { product_key => price(Float) }. UnitOfMeasureType 0 = case.
    def fetch_prices(product_keys)
      ctx = account_context
      out = {}
      Array(product_keys).uniq.each_slice(PRICE_BATCH_SIZE) do |batch|
        body = {
          'BusinessUnitKey' => ctx[:business_unit_key],
          'OperationCompanyNumber' => ctx[:operation_company_number],
          'CustomerId' => ctx[:customer_id],
          'DeliveryDate' => ctx[:delivery_date],
          'OrderEntryHeaderId' => ctx[:order_entry_header_id],
          'CustomerProductPriceRequests' => batch.map do |key|
            { 'ProductKey' => key.to_s, 'UnitOfMeasureType' => 0, 'OrderEntryDetailId' => nil, 'LastViewedPrice' => nil }
          end,
          'IgnoreRetry' => false
        }
        res = call('CustomerProductPrice', 'GetOrderEntryCustomerProductPrice', body)
        prices = res&.dig('ResultObject', 'CustomerProductPrices') || []
        prices.each do |p|
          price = p['Price']
          out[p['ProductKey'].to_s] = price.to_f if price.present? && price.to_f.positive?
        end
      end
      out
    end

    # The customer's saved product lists (order guides). Returns the array of
    # header hashes ({ ProductListHeaderId, ProductListTitle, ProductListType, ... }).
    def list_headers
      res = call('ProductListHeader', 'GetProductListHeaders', nil, http_method: :get,
                                                               query: { 'customerId' => account_context[:customer_id] })
      res&.dig('ResultObject') || []
    end

    # All products in one order guide, flattened across its categories. Each entry
    # is { product: <CatalogProduct hash>, category_title:, sequence: }. Prices are
    # NOT included in this response — merge via fetch_prices on the ProductKeys.
    def list_products(list_header_id, sort_by_type: 5)
      body = {
        'CustomerId' => account_context[:customer_id],
        'ProductListHeaderId' => list_header_id,
        'QueryText' => '',
        'SortByType' => sort_by_type,
        'IncludeRecipeItems' => true
      }
      res = call('ProductListSearch', 'SearchProductList', body)
      unless res && res['IsSuccess']
        raise ApiError, "SearchProductList failed for #{list_header_id}: #{res && res['ErrorMessages']}"
      end

      categories = res.dig('ResultObject', 'ProductListCategories') || []
      categories.flat_map do |cat|
        Array(cat['Products']).filter_map do |detail|
          product = detail['Product']
          next if product.nil?

          { product: product, category_title: cat['CategoryTitle'], sequence: detail['Sequence'] }
        end
      end
    end

    # ── Ordering (phase 7) ─────────────────────────────────────────
    # READ helpers are always safe. WRITE helpers (update_order_detail,
    # submit_order) mutate the customer's real draft order and must only be
    # called through PerformanceScraper's cart-write guard.

    # The active draft order header (READ). Returns the ResultObject hash
    # ({ OrderEntryHeaderId, DeliveryDate, TotalQuantity, ... }).
    def active_order
      call('OrderEntryHeader', 'GetActiveOrder', nil, http_method: :get,
                                                 query: { 'CustomerId' => account_context[:customer_id] })
        &.dig('ResultObject')
    end

    # Full draft order incl. header totals and line items (READ).
    def get_order(order_entry_header_id)
      call('Order', 'GetOrder', nil, http_method: :get,
                                query: { 'orderEntryHeaderId' => order_entry_header_id })
        &.dig('ResultObject')
    end

    # Extract the draft's line items as [{ product_key:, sku:, quantity:,
    # uom_type:, detail_id: }] (READ). PFG only exposes the line array once the
    # cart has content; the key/shape is inferred from the OrderEntryDetail
    # field names and must be confirmed against a populated cart (Stage B).
    def order_lines(order_entry_header_id)
      order = get_order(order_entry_header_id) || {}
      raw = order['OrderEntryDetails'] || order['Details'] || order['OrderEntryHeaderDetails'] || []
      Array(raw).map do |line|
        {
          product_key: (line['ProductKey'] || line['ProductNumber']).to_s,
          sku: (line['ProductNumber'] || line['ProductKey']).to_s,
          quantity: (line['Quantity'] || line['QuantityOrdered']).to_i,
          uom_type: line['UnitOfMeasureType'] || 0,
          detail_id: line['OrderEntryDetailId']
        }
      end
    end

    # WRITE — set a line item's quantity on the draft (add/update). Guarded by
    # PerformanceScraper#cart_writes_enabled?; never call directly in Stage A.
    def update_order_detail(order_entry_header_id:, product_key:, quantity:, uom_type: 0, detail_id: nil)
      ctx = account_context
      body = {
        'OrderEntryHeaderId' => order_entry_header_id,
        'CustomerId' => ctx[:customer_id],
        'OperationCompanyNumber' => ctx[:operation_company_number],
        'BusinessUnitKey' => ctx[:business_unit_key],
        'DeliveryDate' => ctx[:delivery_date],
        'ProductKey' => product_key.to_s,
        'UnitOfMeasureType' => uom_type,
        'Quantity' => quantity.to_i,
        'OrderEntryDetailId' => detail_id
      }
      call('OrderEntryDetail', 'UpdateOrderEntryDetail', body)
    end

    # WRITE — submit the draft order (point of no return). Guarded; never
    # reachable in Stage A. Live shape unverified until a real order is placed.
    def submit_order(order_entry_header_id)
      call('OrderEntryHeader', 'SubmitOrderEntryHeader',
           { 'OrderEntryHeaderId' => order_entry_header_id, 'CustomerId' => account_context[:customer_id] })
    end

    # Generic RPC call: call('Order', 'GetOrderCart', body). The middleware is
    # POST-heavy; pass http_method: :get for the few GET-style routes, with an
    # optional query: hash for GET query parameters.
    def call(service, method, body = nil, http_method: :post, query: nil)
      raise AuthError, 'No access token — call restore_session first' if @access_token.blank?

      uri = URI("#{API_BASE}/api/#{service}/V1/#{method}")
      uri.query = URI.encode_www_form(query) if query.present?
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30

      req = http_method == :get ? Net::HTTP::Get.new(uri.request_uri) : Net::HTTP::Post.new(uri.request_uri)
      req['Authorization'] = "Bearer #{@access_token}"
      req['Accept'] = 'application/json'
      if body && http_method != :get
        req['Content-Type'] = 'application/json'
        req.body = body.to_json
      end

      res = http.request(req)

      # CustomerFirst returns 203 Non-Authoritative instead of 401 when the
      # bearer token is missing/invalid. Never treat it as a good response.
      raise AuthError, "Unauthenticated (HTTP #{res.code}) for #{service}/#{method}" if res.code.to_i == 203 || res.code.to_i == 401

      unless res.is_a?(Net::HTTPSuccess)
        raise ApiError, "HTTP #{res.code} for #{service}/#{method}: #{res.body.to_s.truncate(300)}"
      end

      res.body.present? ? JSON.parse(res.body) : nil
    end

    private

    # Find the first MSAL cache entry whose key contains `marker` and whose
    # JSON value passes the optional filter block.
    def msal_entry(storage, marker)
      storage.each do |key, value|
        next unless key.to_s.downcase.include?(marker)

        parsed = begin
          JSON.parse(value)
        rescue StandardError
          nil
        end
        next unless parsed.is_a?(Hash) && parsed['secret'].present?
        next if block_given? && !yield(parsed)

        return parsed
      end
      nil
    end
  end
end
