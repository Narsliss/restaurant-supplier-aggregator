# frozen_string_literal: true

module Scrapers
  # Performance Foodservice (PFG) via the CustomerFirst platform.
  #
  # CustomerFirst is a React SPA (www.customerfirstsolutions.com) backed by an
  # RPC-style middleware API on Azure. Auth is Azure AD B2C with a CUSTOM policy
  # (B2C_1A_signup_signin, Identity Experience Framework) — same family as
  # US Foods, but plain email + password with no 2FA step.
  #
  # The SPA uses MSAL.js: after login it acquires bearer tokens and caches them
  # in browser storage under MSAL's key scheme. We persist cookies + both
  # storages to session_data; PerformanceApi digs the API access/refresh tokens
  # out of that MSAL cache.
  #
  # Current scope: authentication + session persistence only. Catalog, lists,
  # and ordering land in later phases (see docs/prd-performance-integration.md).
  class PerformanceScraper < BaseScraper
    BASE_URL = 'https://www.customerfirstsolutions.com'
    LOGIN_URL = "#{BASE_URL}/?bu=performance"

    # The B2C hosted page (pfgcustomerfirst.b2clogin.com). Loading LOGIN_URL
    # while unauthenticated redirects here automatically via MSAL.
    IDENTITY_HOST_PATTERN = /b2clogin\.com|login\.microsoftonline\.com/i

    USERNAME_FIELD = '#signInName'
    PASSWORD_FIELD = '#password'
    SUBMIT_BUTTON = '#next'

    def api_client
      @api_client ||= PerformanceApi.new(credential)
    end

    def login
      with_browser do
        if restore_session
          navigate_to(BASE_URL)
          wait_until_logged_in(timeout: 15)

          if logged_in?
            save_session
            credential.mark_active!
            return true
          end

          logger.info '[Performance] Session restore failed, clearing stale cookies for fresh login'
          browser.cookies.clear
        end

        perform_login_steps
        log_api_traffic
        finalize_login
      end
    end

    def soft_refresh
      with_browser do
        if restore_session
          navigate_to(BASE_URL)
          wait_until_logged_in(timeout: 15)

          if logged_in?
            save_session
            credential.mark_active!
            logger.info '[Performance] Soft refresh successful - session extended'
            return true
          end
        end
        logger.info '[Performance] Soft refresh failed - session expired'
        false
      end
    rescue StandardError => e
      logger.warn "[Performance] Soft refresh error: #{e.message}"
      false
    end

    # Signed in when we're back on the app origin (not parked on the B2C page)
    # and MSAL has cached an account/token in browser storage.
    def logged_in?
      current_url = browser.current_url.to_s
      return false if current_url.match?(IDENTITY_HOST_PATTERN)
      return false unless current_url.start_with?(BASE_URL)

      browser.evaluate(<<~JS)
        (function() {
          var keys = Object.keys(localStorage).concat(Object.keys(sessionStorage));
          return keys.some(function(k) {
            return k.indexOf('msal.account.keys') === 0 || k.indexOf('-accesstoken-') !== -1;
          });
        })()
      JS
    rescue StandardError
      false
    end

    # ── Catalog import (phase 3) ───────────────────────────────────
    # Pure API, no browser: paginate SearchProductCatalog per term, merge in
    # customer prices, yield batches in the importer's expected shape.
    MAX_CATALOG_PAGES = 40        # NumberOfPages caps at 100; 40*25 = 1000/term
    CATALOG_PAGE_SIZE = 25
    CATALOG_BATCH_SIZE = 250      # products per import_batch flush

    def scrape_catalog(search_terms, max_per_term: nil, &on_batch)
      api_client.ensure_session!

      max_pages = max_per_term ? (max_per_term.to_f / CATALOG_PAGE_SIZE).ceil : MAX_CATALOG_PAGES
      seen = Set.new
      buffer = []
      results = []

      flush = lambda do
        return if buffer.empty?

        prices = api_client.fetch_prices(buffer.map { |p| p['ProductKey'] })
        formatted = buffer.map { |p| format_catalog_product(p, prices) }
        if on_batch
          on_batch.call(formatted)
        else
          results.concat(formatted)
        end
        buffer = []
      end

      Array(search_terms).each do |term|
        (0...max_pages).each do |page|
          ro = api_client.search_catalog(term, page: page, page_size: CATALOG_PAGE_SIZE)
          products = ro && ro['CatalogProducts']
          break if products.blank?

          products.each do |product|
            sku = product['ProductNumber'].to_s
            next if sku.blank? || seen.include?(sku)

            seen.add(sku)
            buffer << product
            flush.call if buffer.size >= CATALOG_BATCH_SIZE
          end

          number_of_pages = ro['NumberOfPages'].to_i
          break if number_of_pages.positive? && page + 1 >= number_of_pages
          break if products.size < CATALOG_PAGE_SIZE

          rate_limit_delay
        end
        flush.call # keep prices scoped per-term-ish; also bounds buffer memory
      rescue Scrapers::PerformanceApi::ApiError => e
        logger.warn "[Performance] Catalog search failed for '#{term}': #{e.message}"
      end

      logger.info "[Performance] Catalog scrape saw #{seen.size} unique products across #{Array(search_terms).size} terms"
      on_batch ? [] : results.uniq { |r| r[:supplier_sku] }
    end

    def scrape_lists
      logger.info '[Performance] scrape_lists not implemented yet — returning []'
      []
    end

    def scrape_prices(_product_skus)
      logger.info '[Performance] scrape_prices not implemented yet — returning []'
      []
    end

    protected

    def perform_login_steps
      navigate_to(LOGIN_URL)

      # MSAL redirects to the B2C hosted login. Wait for the form to render.
      wait_for_selector(USERNAME_FIELD, timeout: 30)
      detect_error_conditions

      fill_field(USERNAME_FIELD, credential.username)
      fill_field(PASSWORD_FIELD, credential.password)
      check_remember_me
      click(SUBMIT_BUTTON)

      wait_for_redirect_to_app(timeout: 30)

      # Give the SPA time to boot and MSAL time to acquire the API-scope
      # access token — save_session must capture it for PerformanceApi.
      wait_until_logged_in(timeout: 20)
    end

    # Map a raw CatalogProduct + merged price into the shape
    # ImportSupplierProductsService expects.
    #
    # CRITICAL — catch-weight pricing: for a catch-weight case UOM, PFG's Price
    # is the PER-POUND price, not the case price (e.g. $1.64/lb for a ~39 lb
    # case). Storing it raw would make PFG look ~40x cheaper than reality and
    # corrupt every savings comparison. The UOM-level ProductIsCatchWeight flag
    # is authoritative (the top-level flag is always false); when set, the case
    # price is Price x ProductAverageWeight. Non-catch-weight Price is already
    # the case price.
    def format_catalog_product(product, prices)
      sku = product['ProductNumber'].to_s
      uom = Array(product['UnitOfMeasureOrderQuantities']).first || {}
      pack = [uom['PackSize'], uom['UnitOfMeasureAbbreviation']].compact.join(' ').presence

      raw_price = prices[product['ProductKey'].to_s]
      avg_weight = uom['ProductAverageWeight'].to_f
      case_price =
        if raw_price && uom['ProductIsCatchWeight'] && avg_weight.positive?
          (raw_price * avg_weight).round(2)
        else
          raw_price
        end

      {
        supplier_sku: sku,
        supplier_name: [product['ProductBrand'].presence, product['ProductDescription']].compact.join(' - '),
        current_price: case_price,
        pack_size: pack,
        # Don't set stock from catalog — only the order-guide sync has the
        # per-location context to mark items out of stock (see USF).
        in_stock: nil,
        category: product['ProductCategory'].presence&.titleize,
        subcategory: product['ShoppingCategory'].presence,
        supplier_url: nil,
        image_url: product['ProductImageUrlThumbnail'].presence
      }
    end

    # US Foods stores auth in localStorage/sessionStorage; CustomerFirst's
    # MSAL cache works the same way, so persist all three stores.
    def save_session
      cookies = browser.cookies.all.transform_values(&:to_h)
      local_storage = read_web_storage('localStorage')
      session_storage = read_web_storage('sessionStorage')

      credential.update!(
        session_data: {
          cookies: cookies,
          local_storage: local_storage,
          session_storage: session_storage
        }.to_json,
        last_login_at: Time.current,
        status: 'active'
      )
      logger.info "[Performance] Session saved (cookies: #{cookies.size}, localStorage: #{local_storage.size}, sessionStorage: #{session_storage.size})"
    end

    def restore_session
      return false unless credential.session_data.present?
      return false unless credential.session_valid?

      data = JSON.parse(credential.session_data)
      cookies = data['cookies'] || {}
      local_storage = data['local_storage'] || {}
      session_storage = data['session_storage'] || {}

      cookies.each do |_name, cookie|
        next unless cookie.is_a?(Hash) && cookie['name'].present? && cookie['value'].present?

        params = {
          name: cookie['name'].to_s,
          value: cookie['value'].to_s,
          domain: cookie['domain'].to_s,
          path: cookie['path'].present? ? cookie['path'].to_s : '/'
        }
        params[:secure] = !!cookie['secure'] unless cookie['secure'].nil?
        params[:httponly] = !!cookie['httponly'] unless cookie['httponly'].nil?
        params[:expires] = cookie['expires'].to_i if cookie['expires'].is_a?(Numeric) && cookie['expires'] > 0
        begin
          browser.cookies.set(**params)
        rescue StandardError
          nil
        end
      end

      # Need a page on the app origin before storage can be injected.
      begin
        browser.goto(BASE_URL)
      rescue Ferrum::PendingConnectionsError
        # SPA keeps connections open; the DOM is still usable.
      end
      sleep 2

      write_web_storage('localStorage', local_storage)
      write_web_storage('sessionStorage', session_storage)

      logger.info "[Performance] Session restored (cookies: #{cookies.size}, localStorage: #{local_storage.size}, sessionStorage: #{session_storage.size})"
      true
    rescue JSON::ParserError => e
      logger.warn "[Performance] Failed to parse session data: #{e.message}"
      false
    end

    private

    def wait_for_redirect_to_app(timeout: 30)
      deadline = Time.current + timeout
      loop do
        url = browser.current_url.to_s
        return true if url.start_with?(BASE_URL) && !url.match?(IDENTITY_HOST_PATTERN)

        if Time.current > deadline
          error = extract_visible_text('.error, .error.pageLevel, .error.itemLevel, [role="alert"]')
          message = error.presence || 'Timed out waiting for redirect back to CustomerFirst after sign-in'
          raise AuthenticationError, message
        end

        # Surface B2C validation errors (bad password etc.) as soon as they render.
        if browser.current_url.to_s.match?(IDENTITY_HOST_PATTERN)
          error = extract_visible_text('.error.pageLevel, .error.itemLevel')
          raise AuthenticationError, error if error.present?
        end

        sleep 1
      end
    end

    def wait_until_logged_in(timeout: 15)
      deadline = Time.current + timeout
      until logged_in?
        return false if Time.current > deadline

        sleep 2
      end
      true
    end

    def read_web_storage(store)
      browser.evaluate(<<~JS)
        (function() {
          var data = {};
          for (var i = 0; i < #{store}.length; i++) {
            var key = #{store}.key(i);
            data[key] = #{store}.getItem(key);
          }
          return data;
        })()
      JS
    rescue StandardError
      {}
    end

    def write_web_storage(store, data)
      return if data.blank?

      browser.evaluate(<<~JS)
        (function() {
          var data = #{data.to_json};
          Object.keys(data).forEach(function(key) {
            try { #{store}.setItem(key, data[key]); } catch(e) {}
          });
        })()
      JS
    rescue StandardError => e
      logger.debug "[Performance] Could not restore #{store}: #{e.message}"
    end

    # Route recon: log the middleware calls the SPA made during this browser
    # session so we can see live request shapes for the API-client phase.
    def log_api_traffic
      exchanges = browser.network.traffic.select do |exchange|
        exchange.request&.url.to_s.include?('azurewebsites.net')
      end
      exchanges.first(50).each do |exchange|
        req = exchange.request
        status = exchange.response&.status
        logger.info "[Performance][API-recon] #{req.method} #{sanitize_url(req.url)} -> #{status}"
      end
      logger.info "[Performance][API-recon] observed #{exchanges.size} middleware calls"
    rescue StandardError => e
      logger.debug "[Performance] API traffic logging failed: #{e.message}"
    end
  end
end
