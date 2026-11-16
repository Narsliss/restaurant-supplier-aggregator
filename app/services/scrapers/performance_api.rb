# frozen_string_literal: true

require 'base64'
require 'cgi'
require 'digest'
require 'set'

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

    # Sign-in without a browser (#sign_in): the B2C hosted page and the
    # settings the CustomerFirst SPA uses (its public main.js, Oct 21 2026).
    SIGN_IN_AUTHORITY = 'https://pfgcustomerfirst.b2clogin.com/pfgcustomerfirst.onmicrosoft.com/B2C_1A_signup_signin'
    SIGN_IN_POLICY = 'B2C_1A_signup_signin'
    SIGN_IN_REDIRECT_URI = 'https://www.customerfirstsolutions.com'
    SIGN_IN_SCOPE = "openid profile offline_access https://pfgcustomerfirst.onmicrosoft.com/api/#{API_SCOPE_HOST}"
    SIGN_IN_USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' \
                         '(KHTML, like Gecko) Chrome/129.0 Safari/537.36'
    # Where #sign_in keeps its tokens when the stored session has no MSAL
    # entries to update (a login that never had a browser session).
    SIGNED_IN_ACCESS_KEY = "enplace-signin-accesstoken-#{CLIENT_ID}--#{API_SCOPE_HOST}".freeze
    SIGNED_IN_REFRESH_KEY = "enplace-signin-refreshtoken-#{CLIENT_ID}--".freeze

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

    # When the login behind the refresh token ends, as B2C reported on this
    # client's last refresh; nil when no refresh happened or none was reported.
    # A login lasts 24 hours from a real sign-in and refreshing can't extend
    # it: near the end B2C still answers, with a refresh token good for seconds
    # (Oct 21 2026: 6 s, then "AADB2C90080: The provided grant has expired").
    attr_reader :refresh_token_expires_at

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
      @refreshed_at = Time.current
      @refresh_token_expires_at = (Time.current + payload['refresh_token_expires_in'].to_i if payload['refresh_token_expires_in'].present?)
      # refresh_token_expires_in tells us how long a Performance login lasts
      # without a browser (open item in docs/prd-performance-integration.md).
      logger.info "[Performance-API] Access token refreshed (expires #{@token_expires_at}; " \
                  "refresh token lasts #{payload['refresh_token_expires_in'].inspect}s)"
      @access_token.present?
    rescue StandardError => e
      logger.warn "[Performance-API] Token refresh error: #{e.class}: #{e.message}"
      false
    end

    def token_expired?
      @token_expires_at.nil? || @token_expires_at <= Time.current + 60
    end

    # Write tokens this client refreshed back into the stored MSAL cache, so
    # the next restore — API or browser — starts from them. B2C hands back a
    # new refresh token on every refresh; before this only a browser session
    # ever saved one. Returns true when an entry was updated. Never raises: a
    # failed save only means the next restore starts from the older tokens.
    def persist_tokens!
      return false if @access_token.blank? || @refreshed_at.nil?

      data = JSON.parse(credential.session_data.to_s)
      return false if write_tokens_into(data).empty?

      credential.update!(session_data: data.to_json)
      true
    rescue StandardError => e
      logger.warn "[Performance-API] Could not save refreshed tokens: #{e.class}: #{e.message}"
      false
    end

    # Sign in with the login's stored email + password over plain HTTP: the
    # five requests B2C's hosted sign-in page makes, no browser. Proven on a
    # real login Oct 21 2026 (docs/recon-performance-http-signin.md); every
    # fresh sign-in starts a new 24-hour login. Returns
    #   :signed_in  new tokens loaded and saved to session_data
    #   :rejected   B2C answered the email/password step with a refusal
    #               (wrong password, locked account); its message is logged
    #   :failed     anything else (page changed, no code, token error,
    #               network), so the caller can fall back to Chrome
    # Never logs or raises with a password, token, cookie or code.
    def sign_in
      return sign_in_failed('no stored email or password') if credential.username.blank? || credential.password.blank?

      jar = {}
      verifier = Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
      authorize_url = sign_in_authorize_url(verifier)

      # 1. The sign-in page: its CSRF token and transaction id.
      page = sign_in_request(:get, authorize_url, jar)
      settings = sign_in_settings(page.body)
      csrf = settings['csrf']
      tx = settings['transId']
      return sign_in_failed("no sign-in form (HTTP #{page.code})") if csrf.blank? || tx.blank?

      # 2. Email + password.
      answer = sign_in_request(
        :post, "#{SIGN_IN_AUTHORITY}/SelfAsserted?tx=#{CGI.escape(tx)}&p=#{SIGN_IN_POLICY}", jar,
        form: { 'request_type' => 'RESPONSE', 'signInName' => credential.username, 'password' => credential.password },
        headers: { 'X-CSRF-TOKEN' => csrf, 'X-Requested-With' => 'XMLHttpRequest',
                   'Accept' => 'application/json, text/javascript, */*; q=0.01',
                   'Origin' => 'https://pfgcustomerfirst.b2clogin.com', 'Referer' => authorize_url }
      )
      return sign_in_failed("credentials step HTTP #{answer.code}") unless answer.code == '200'

      verdict = parse_json(answer.body)
      unless verdict['status'].to_s == '200'
        logger.warn "[Performance-API] Sign-in refused: #{verdict['message'].presence || "status #{verdict['status'].inspect}"}"
        return :rejected
      end

      # 3. Confirm: B2C redirects to the app with the authorization code.
      confirmed = sign_in_request(
        :get, "#{SIGN_IN_AUTHORITY}/api/CombinedSigninAndSignup/confirmed?rememberMe=false" \
              "&csrf_token=#{CGI.escape(csrf)}&tx=#{CGI.escape(tx)}&p=#{SIGN_IN_POLICY}", jar,
        headers: { 'Referer' => authorize_url }
      )
      code = sign_in_code(confirmed['location'])
      return sign_in_failed("no authorization code (HTTP #{confirmed.code})") if code.blank?

      # 4. Exchange the code for tokens, as the single-page app does.
      tokens = sign_in_request(
        :post, TOKEN_ENDPOINT, jar,
        form: { 'grant_type' => 'authorization_code', 'client_id' => CLIENT_ID, 'code' => code,
                'redirect_uri' => SIGN_IN_REDIRECT_URI, 'code_verifier' => verifier, 'scope' => SIGN_IN_SCOPE },
        headers: { 'Origin' => SIGN_IN_REDIRECT_URI }
      )
      payload = parse_json(tokens.body)
      unless tokens.is_a?(Net::HTTPSuccess) && payload['access_token'].present?
        return sign_in_failed("token step HTTP #{tokens.code} #{payload['error']}".strip)
      end

      load_signed_in_tokens(payload)
      save_signed_in_tokens!
      logger.info '[Performance-API] Signed in without a browser ' \
                  "(login lasts #{payload['refresh_token_expires_in'].inspect}s)"
      :signed_in
    rescue StandardError => e
      sign_in_failed(e.class.name)
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

    # The draft order HEADER incl. totals (READ). Verified live to return
    # TotalLines / TotalQuantity / TotalOrderPrice / MinimumOrderAmount /
    # CutoffDateTime / DeliveryDate — but NOT the line items (the SPA keeps line
    # state client-side from UpdateOrderEntryDetail responses).
    def get_order(order_entry_header_id)
      call('Order', 'GetOrder', nil, http_method: :get,
                                query: { 'orderEntryHeaderId' => order_entry_header_id })
        &.dig('ResultObject')
    end

    # OPEN ITEM — no per-line read endpoint has been found. GetOrder and
    # GetOrderCart are header-only; the SPA never re-fetches the line list. Until
    # one is identified, this returns []. Consumers must NOT rely on it for
    # reconciliation — verify_cart_matches! reconciles on GetOrder TOTALS instead.
    def order_lines(_order_entry_header_id)
      []
    end

    # WRITE — set a line item's quantity on the draft (add/update/remove).
    # Quantity is ABSOLUTE (a set, not an increment); 0 removes the line.
    # Guarded by PerformanceScraper#cart_writes_enabled?.
    #
    # PFG requires the FULL product payload here, not just the ProductKey — a
    # minimal body returns IsSuccess:true but silently creates no line (verified
    # live). `product` is the CatalogProduct hash (from product_by_sku); `price`
    # is the raw per-UOM price (from fetch_prices). Passing NO_ACTIVE_ORDER as
    # the header auto-creates a draft and returns its real id in
    # ResultObject.OrderEntryHeaderId.
    def update_order_detail(order_entry_header_id:, product:, quantity:, price:, uom_type: 0)
      ctx = account_context
      uom = Array(product['UnitOfMeasureOrderQuantities']).first || {}
      body = {
        'OrderEntryHeaderId' => order_entry_header_id,
        'BusinessUnitKey' => ctx[:business_unit_key],
        'BusinessUnitERPKey' => product['BusinessUnitERPKey'],
        'CustomerId' => ctx[:customer_id],
        'ProductKey' => product['ProductKey'].to_s,
        'UnitOfMeasureType' => uom_type,
        'Quantity' => quantity.to_i,
        'Price' => price,
        'ProductNumber' => product['ProductNumber'].to_s,
        'ProductDescription' => product['ProductDescription'],
        'ProductBrand' => product['ProductBrand'],
        'ProductPackSize' => uom['PackSize'],
        'ProductIsCatchWeight' => uom['ProductIsCatchWeight'] || false,
        'ProductAverageWeight' => uom['ProductAverageWeight'] || 0,
        'ShipLaterMaxEstimatedDays' => product['ShipLaterMaxEstimatedDays'] || 0,
        'CutoffDateTime' => nil,
        'UOMOrderQuantityAlertThresholdMin' => uom['UOMOrderQuantityAlertThresholdMin'] || 0,
        'UOMOrderQuantityAlertThresholdMax' => uom['UOMOrderQuantityAlertThresholdMax'] || 0
      }
      call('OrderEntryDetail', 'UpdateOrderEntryDetail', body)
    end

    # WRITE — submit the draft order (point of no return).
    #
    # Shape taken from CustomerFirst's own site code (main bundle, Sep 27 2026):
    # submitOrderEntryHeader posts { OrderEntryHeaderId, TimeZone } in
    # "queryParams" mode — POST with an EMPTY {} body and the fields as URL
    # query parameters. Sending them in the JSON body (as the first version did,
    # with CustomerId) is answered "Order not found." — order #334's failure.
    # Success is IsSuccess AND ResultObject.AcceptOrder (checked by the scraper).
    def submit_order(order_entry_header_id)
      call('OrderEntryHeader', 'SubmitOrderEntryHeader', {},
           query: { 'OrderEntryHeaderId' => order_entry_header_id, 'TimeZone' => time_zone })
    end

    # WRITE — set the draft's delivery date (the site's updateDeliveryDate: JSON
    # body { OrderEntryHeaderId, DeliveryDate }). Without it the draft keeps
    # PFG's own default date: order #334 was built for Sep 28, not the Oct 2 the
    # chef picked. Date sent in PFG's own format ("2026-10-02T00:00:00").
    def update_delivery_date(order_entry_header_id, date)
      call('OrderEntryHeader', 'UpdateOrderEntryHeaderDeliveryDate',
           { 'OrderEntryHeaderId' => order_entry_header_id, 'DeliveryDate' => "#{date.to_date.iso8601}T00:00:00" })
    end

    # READ — the account's deliverable dates, as the site's own date picker gets
    # them (Customer/GetCustomerDeliveryDates). Returns
    # { dates: ["2026-09-29", ...], error: nil } — or, for an account PFG won't
    # deliver to, { dates: [], error: "You are not currently set up for
    # deliveries. ..." } (alfios, Sep 27 2026). Transport failures raise.
    def customer_delivery_dates
      res = call('Customer', 'GetCustomerDeliveryDates', nil, http_method: :get,
                 query: { 'customerId' => account_context[:customer_id], 'ignoreCutOff' => false })
      if res && res['IsSuccess']
        dates = Array(res['ResultObject']).filter_map { |d| (Date.parse(d.to_s) rescue nil)&.iso8601 }.uniq.sort
        { dates: dates, error: nil }
      else
        { dates: [], error: Array(res && res['ErrorMessages']).join(' ').presence || 'Performance returned no delivery dates' }
      end
    end

    # WRITE — delete an unsubmitted draft (the site's deleteOrderEntryHeader,
    # "queryParams" mode). PFG has no per-line read, so emptying a cart line by
    # line is impossible; deleting the draft is how the site discards one.
    def delete_order_entry_header(order_entry_header_id)
      call('OrderEntryHeader', 'DeleteOrderEntryHeader', {}, query: { 'OrderEntryHeaderId' => order_entry_header_id })
    end

    # After deleting the open draft, reads and the next add use the
    # no-active-order sentinel again (the next add creates a fresh draft).
    def forget_active_order!
      account_context[:order_entry_header_id] = NO_ACTIVE_ORDER
    end

    # IANA name the site sends (Intl...resolvedOptions().timeZone). Restaurants
    # are in the app's zone (Eastern).
    def time_zone
      Time.zone.tzinfo.identifier
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

    # Puts this client's tokens into the stored MSAL cache entries, in place,
    # so the next restore (API or browser) starts from them. Returns the
    # kinds updated: :access and/or :refresh.
    def write_tokens_into(data)
      updated = Set.new

      %w[local_storage session_storage].each do |store|
        entries = data[store]
        next unless entries.is_a?(Hash)

        entries.keys.each do |key|
          entry = begin
            JSON.parse(entries[key].to_s)
          rescue JSON::ParserError
            nil
          end
          next unless entry.is_a?(Hash) && entry['secret'].present?

          name = key.to_s.downcase
          if name.include?('-accesstoken-') && entry['target'].to_s.include?(API_SCOPE_HOST)
            entry['secret'] = @access_token
            entry['expiresOn'] = @token_expires_at.to_i.to_s
            entry['extendedExpiresOn'] = @token_expires_at.to_i.to_s if entry.key?('extendedExpiresOn')
            entry['cachedAt'] = @refreshed_at.to_i.to_s if entry.key?('cachedAt')
            updated << :access
          elsif name.include?('-refreshtoken-') && @refresh_token.present?
            entry['secret'] = @refresh_token
            updated << :refresh
          else
            next
          end

          entries[key] = entry.to_json
        end
      end
      updated
    end

    # ── Sign-in without a browser (#sign_in) ─────────────────────────────

    def sign_in_authorize_url(verifier)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      "#{SIGN_IN_AUTHORITY}/oauth2/v2.0/authorize?" + URI.encode_www_form(
        client_id: CLIENT_ID, redirect_uri: SIGN_IN_REDIRECT_URI, response_type: 'code', response_mode: 'query',
        scope: SIGN_IN_SCOPE, code_challenge: challenge, code_challenge_method: 'S256',
        state: SecureRandom.hex(8), nonce: SecureRandom.hex(8)
      )
    end

    # One request of the sign-in, carrying B2C's cookies (jar) between them.
    # Redirects are not followed: step 3's redirect is where the code is.
    def sign_in_request(method, url, jar, form: nil, headers: {})
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15
      http.read_timeout = 30

      req = method == :get ? Net::HTTP::Get.new(uri.request_uri) : Net::HTTP::Post.new(uri.request_uri)
      req['User-Agent'] = SIGN_IN_USER_AGENT
      req['Cookie'] = jar.map { |name, value| "#{name}=#{value}" }.join('; ') if jar.any?
      headers.each { |name, value| req[name] = value }
      req.set_form_data(form) if form

      res = http.request(req)
      Array(res.get_fields('set-cookie')).each do |cookie|
        name, value = cookie.split(';').first.to_s.split('=', 2)
        jar[name] = value if name.present?
      end
      res
    end

    def sign_in_settings(html)
      json = html.to_s[/var SETTINGS = (\{.*?\});/m, 1]
      json ? parse_json(json) : {}
    end

    def sign_in_code(location)
      return nil if location.blank?

      URI.decode_www_form(URI(location).query.to_s).to_h['code']
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def parse_json(text)
      parsed = JSON.parse(text.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def load_signed_in_tokens(payload)
      @access_token = payload['access_token']
      @refresh_token = payload['refresh_token'] if payload['refresh_token'].present?
      @token_scopes = payload['scope'].presence || SIGN_IN_SCOPE
      @token_expires_at = Time.current + payload['expires_in'].to_i
      @refreshed_at = Time.current
      @refresh_token_expires_at = (Time.current + payload['refresh_token_expires_in'].to_i if payload['refresh_token_expires_in'].present?)
    end

    # Saves the new tokens: into the existing MSAL entries when the stored
    # session has them (so a browser restore still finds its account), else
    # into entries of our own in the shape #restore_session reads.
    def save_signed_in_tokens!
      data = parse_json(credential.session_data)
      written = write_tokens_into(data)
      data['local_storage'] = {} unless data['local_storage'].is_a?(Hash)

      unless written.include?(:access)
        data['local_storage'][SIGNED_IN_ACCESS_KEY] = {
          'credentialType' => 'AccessToken', 'secret' => @access_token, 'target' => @token_scopes,
          'expiresOn' => @token_expires_at.to_i.to_s, 'cachedAt' => @refreshed_at.to_i.to_s
        }.to_json
      end
      unless written.include?(:refresh) || @refresh_token.blank?
        data['local_storage'][SIGNED_IN_REFRESH_KEY] = { 'credentialType' => 'RefreshToken', 'secret' => @refresh_token }.to_json
      end
      data['cookies'] = {} unless data['cookies'].is_a?(Hash)
      data['session_storage'] = {} unless data['session_storage'].is_a?(Hash)

      credential.update!(session_data: data.to_json)
    end

    def sign_in_failed(reason)
      logger.warn "[Performance-API] Sign-in without a browser did not complete: #{reason}"
      :failed
    end
  end
end
