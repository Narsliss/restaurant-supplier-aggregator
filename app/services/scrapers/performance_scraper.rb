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
    MAX_CATALOG_PAGES = 10        # 10*100 = 1000/term; a term rarely exceeds a few hundred
    CATALOG_PAGE_SIZE = 100       # verified live: PFG honors 100/page (4x fewer calls than 25)
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

    # ── Order guides / lists (phase 5) ─────────────────────────────
    # Pure API. GetProductListHeaders → real order guides (type 3, owned/named);
    # SearchProductList → each guide's items; prices merged via fetch_prices.
    # System lists (all-zeros GUID / unnamed) are skipped.
    def scrape_lists
      api_client.ensure_session!

      headers = api_client.list_headers.select { |h| order_guide_header?(h) }
      logger.info "[Performance] #{headers.size} order guide(s) to sync"

      headers.filter_map do |header|
        list_id = header['ProductListHeaderId']
        entries = api_client.list_products(list_id)
        prices = api_client.fetch_prices(entries.map { |e| e[:product]['ProductKey'] })

        items = entries.each_with_index.map do |entry, idx|
          product = entry[:product]
          {
            sku: product['ProductNumber'].to_s,
            name: product_display_name(product),
            price: case_price_for(product, prices),
            pack_size: product_pack_size(product),
            quantity: 1,
            in_stock: !product['IsOutOfStock'],
            position: entry[:sequence] || idx + 1
          }
        end

        # Fail loudly rather than silently syncing an empty guide over a
        # populated one (cf. the WCW "synced zero items" regression).
        if items.empty?
          logger.warn "[Performance] Order guide '#{header['ProductListTitle']}' (#{list_id}) returned 0 items — skipping"
          next
        end

        {
          name: header['ProductListTitle'].presence || 'Order Guide',
          remote_id: list_id.to_s,
          url: "#{BASE_URL}/list-management/#{list_id}/#{api_client.account_context[:customer_id]}",
          list_type: 'order_guide',
          items: items
        }
      end
    end

    # At-order price verification (PriceVerificationService / VerifyItemPriceJob).
    # Pure API. For each SKU: look it up in the catalog (SKU == ProductKey) to get
    # the UOM/catch-weight fields, then merge the customer price. Catch-weight
    # aware via case_price_for so verification uses the true case price.
    def scrape_prices(product_skus)
      api_client.ensure_session!
      queries = normalize_price_queries(product_skus)
      skus = queries.map { |q| q[:sku] }.reject(&:blank?).uniq
      return [] if skus.empty?

      prices = api_client.fetch_prices(skus)
      results = []
      skus.each do |sku|
        product = api_client.product_by_sku(sku)
        next unless product

        results << {
          supplier_sku: sku,
          current_price: case_price_for(product, prices),
          in_stock: !product['IsOutOfStock'],
          supplier_name: product_display_name(product),
          pack_size: product_pack_size(product)
        }
      rescue Scrapers::PerformanceApi::ApiError => e
        logger.warn "[Performance] scrape_prices: lookup failed for #{sku}: #{e.message}"
      end
      results
    end

    # Pre-order validation hooks (read-only). PFG carries the order minimum and
    # the delivery cutoff on the draft/active order.
    def get_order_minimum
      api_client.ensure_session!
      order = api_client.get_order(active_order_id!) || {}
      minimum = order['MinimumOrderAmount'].to_f
      return nil unless minimum.positive?

      { minimum: minimum }
    rescue Scrapers::PerformanceApi::ApiError => e
      logger.warn "[Performance] get_order_minimum failed: #{e.message}"
      nil
    end

    def get_delivery_availability(_delivery_date = nil)
      api_client.ensure_session!
      order = api_client.get_order(active_order_id!) || {}
      cutoff_raw = order['CutoffDateTime']
      cutoff = begin
        Time.zone.parse(cutoff_raw.to_s) if cutoff_raw.present?
      rescue ArgumentError
        nil
      end

      {
        available: true, # delivery scheduling is validated by PFG at submit
        delivery_date: order['DeliveryDate'],
        cutoff_time: cutoff
      }
    rescue Scrapers::PerformanceApi::ApiError => e
      logger.warn "[Performance] get_delivery_availability failed: #{e.message}"
      nil
    end

    # ── Ordering (phase 7 — Stage A framework) ─────────────────────
    #
    # SAFETY MODEL. PFG's cart IS the customer's real draft order; add-to-cart
    # (UpdateOrderEntryDetail) writes to it, submit (SubmitOrderEntryHeader) is
    # the point of no return.
    #
    # In PRODUCTION Performance orders like every other supplier: cart writes
    # are on and the existing per-supplier `checkout_enabled` kill switch is the
    # gate. OUTSIDE production cart writes are off unless
    # PERFORMANCE_CART_WRITES=true — dev and prod share the customer's REAL PFG
    # account and PFG exposes no line-list read, so a line left by a dev test
    # would sit in the real cart and (correctly) fail verify_cart_matches! on the
    # next real production order. Dev never submits either way (OrderPlacementService
    # forces dry_run outside production).
    #
    # Add-to-cart is verified live (Stage B). The SubmitOrderEntryHeader request
    # and response shapes are unverified until the first real order — checkout
    # therefore refuses to treat anything but IsSuccess:true as placed.
    def cart_writes_enabled?
      Rails.env.production? || ENV.fetch('PERFORMANCE_CART_WRITES', 'false') == 'true'
    end

    # Add/update cart lines. PFG's UpdateOrderEntryDetail needs the full product
    # payload, and passing the no-active-order sentinel auto-creates a draft and
    # returns its real id — which we thread onto @active_draft_id so the later
    # verify/checkout act on the created draft (account_context is memoized to
    # the pre-create sentinel).
    def add_to_cart(items, delivery_date: nil)
      api_client.ensure_session!
      oeh = active_order_id!
      logger.info "[Performance] add_to_cart: #{items.size} item(s), delivery_date=#{delivery_date}, writes_enabled=#{cart_writes_enabled?}"

      added = []
      failed = []
      items.each do |item|
        product_key = item[:sku].to_s
        quantity = item[:quantity].to_i
        next if product_key.blank? || quantity <= 0

        unless cart_writes_enabled?
          logger.info "[Performance][cart-dry-run] would set ProductKey=#{product_key} qty=#{quantity} (no write)"
          added << item
          next
        end

        begin
          product = api_client.product_by_sku(product_key)
          if product.nil?
            failed << item.merge(reason: 'product not found in catalog')
            next
          end
          price = api_client.fetch_prices([product_key])[product_key]
          res = api_client.update_order_detail(order_entry_header_id: oeh, product: product, quantity: quantity, price: price)
          if res && res['IsSuccess']
            # Capture the real draft id created on the first add.
            new_oeh = res.dig('ResultObject', 'OrderEntryHeaderId')
            if new_oeh.present? && new_oeh != Scrapers::PerformanceApi::NO_ACTIVE_ORDER
              @active_draft_id = new_oeh
              oeh = new_oeh
            end
            added << item
          else
            failed << item.merge(reason: (res && res['ErrorMessages'])&.join('; '))
          end
        rescue Scrapers::PerformanceApi::ApiError => e
          failed << item.merge(reason: e.message)
        end
      end

      { added: added, failed: failed }
    end

    def clear_cart
      api_client.ensure_session!
      oeh = active_order_id!

      unless cart_writes_enabled?
        logger.info '[Performance][cart-dry-run] would clear cart (no write)'
        return
      end

      # No open draft → nothing to clear (the sentinel isn't a real order).
      return if oeh == Scrapers::PerformanceApi::NO_ACTIVE_ORDER

      # PFG exposes no line-list read (see PerformanceApi#order_lines), so we
      # cannot enumerate and zero orphaned lines proactively. This is safe:
      # verify_cart_matches! reconciles the draft TOTALS before submit and fails
      # CLOSED on any orphaned/extra line, so a stale draft can never be
      # submitted — it just surfaces as an error the operator resolves.
      lines = api_client.order_lines(oeh)
      if lines.empty?
        logger.info '[Performance] clear_cart: no enumerable lines (verify_cart_matches! guards submit)'
        return
      end

      lines.each do |line|
        product = line[:product] || api_client.product_by_sku(line[:sku])
        next if product.nil?

        api_client.update_order_detail(order_entry_header_id: oeh, product: product, quantity: 0, price: line[:price])
      rescue Scrapers::PerformanceApi::ApiError => e
        logger.warn "[Performance] clear_cart: failed to zero #{line[:sku]}: #{e.message}"
      end
      logger.info '[Performance] cart cleared'
    end

    # Fail CLOSED before submit: the PFG draft's totals must match the order we
    # intend to place, so a stale/orphaned line in the server-side draft can
    # never be submitted (cf. the CW phantom-cart incident). READ-only.
    #
    # PFG exposes no line-list read endpoint (GetOrder/GetOrderCart are
    # header-only; the SPA keeps line state client-side) — see the order_lines
    # open item — so reconciliation is on TOTALS: the draft's TotalLines and
    # TotalQuantity must equal the distinct-SKU count and summed quantity we
    # intend. This catches orphaned/extra lines, missing lines, and quantity
    # errors. It cannot catch a same-count/same-qty SKU SWAP; that residual is
    # bounded because add_to_cart itself echoes each line's ProductKey+qty and we
    # only submit what add_to_cart reported adding.
    def verify_cart_matches!(expected_items)
      api_client.ensure_session!
      oeh = active_order_id!

      # Stage A (cart writes off): add_to_cart wrote nothing, so there is nothing
      # to reconcile and nothing can be submitted — the write guard is the safety.
      unless cart_writes_enabled?
        logger.info '[Performance][cart-dry-run] skipping cart reconciliation (no items were written)'
        return true
      end

      expected = tally_by_sku(expected_items.map { |i| { sku: i[:sku], quantity: i[:quantity] } })
      expected_lines = expected.keys.size
      expected_qty = expected.values.sum

      order = api_client.get_order(oeh) || {}
      cart_lines = order['TotalLines'].to_i
      cart_qty = order['TotalQuantity'].to_i

      discrepancies = []
      discrepancies << { type: 'line_count', cart_lines: cart_lines, expected_lines: expected_lines } if cart_lines != expected_lines
      discrepancies << { type: 'total_quantity', cart_qty: cart_qty, expected_qty: expected_qty } if cart_qty != expected_qty

      if discrepancies.any?
        raise Scrapers::BaseScraper::CartMismatchError.new(
          "Performance draft totals do not match order: #{discrepancies.inspect}",
          discrepancies: discrepancies
        )
      end

      true
    end

    def checkout(dry_run: false)
      api_client.ensure_session!
      oeh = active_order_id!
      order = api_client.get_order(oeh) || {}

      item_count = order['TotalLines'].to_i
      subtotal = (order['TotalOrderPrice'] || order['TotalExtendedPrice']).to_f
      minimum = order['MinimumOrderAmount'].to_f

      if dry_run
        logger.info "[Performance] DRY RUN checkout — lines=#{item_count}, subtotal=$#{subtotal}, minimum=$#{minimum}"
        return {
          confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
          total: subtotal,
          delivery_date: order['DeliveryDate'],
          dry_run: true,
          checkout_summary: { item_count: item_count, subtotal: subtotal, minimum: minimum }
        }
      end

      # A live submit with nothing written to the cart would submit whatever
      # happens to be in the draft. Can't happen in production (writes are on)
      # or via OrderPlacementService (dry_run outside production); guards scripts.
      unless cart_writes_enabled?
        raise ScrapingError, 'Performance live submit refused: cart writes are off outside production'
      end

      raise ScrapingError, 'Performance cart is empty' if item_count.zero?
      if minimum.positive? && subtotal < minimum
        raise OrderMinimumError.new('Order minimum not met', minimum: minimum, current_total: subtotal)
      end

      logger.warn '[Performance] PLACING LIVE ORDER'
      result = api_client.submit_order(oeh)
      # PFG reports rejections as HTTP 200 + IsSuccess:false. That must never
      # read as a placed order — the chef would believe it went out when it didn't.
      unless result.is_a?(Hash) && result['IsSuccess']
        errors = result.is_a?(Hash) ? Array(result['ErrorMessages']).join('; ') : 'no response'
        logger.error "[Performance] submit REJECTED: #{result.inspect.truncate(1500)}"
        raise ScrapingError, "Performance rejected the order: #{errors.presence || 'IsSuccess false'}"
      end
      logger.warn "[Performance] submit response: #{result.inspect.truncate(1500)}"
      # Response shape unverified until the first real order: prefer PFG's order
      # number, else the draft's OrderEntryHeaderId — PFG's own id for this order,
      # never a fabricated one.
      ro = result['ResultObject'].is_a?(Hash) ? result['ResultObject'] : {}
      confirmation = ro['OrderNumber'].presence || ro['ConfirmationNumber'].presence || oeh
      logger.warn "[Performance] LIVE order submitted: #{confirmation}"

      {
        confirmation_number: confirmation,
        total: subtotal,
        delivery_date: order['DeliveryDate'],
        dry_run: false,
        checkout_summary: result
      }
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
    def format_catalog_product(product, prices)
      {
        supplier_sku: product['ProductNumber'].to_s,
        supplier_name: product_display_name(product),
        current_price: case_price_for(product, prices),
        pack_size: product_pack_size(product),
        # Don't set stock from catalog — only the order-guide sync has the
        # per-location context to mark items out of stock (see USF).
        in_stock: nil,
        category: product['ProductCategory'].presence&.titleize,
        subcategory: product['ShoppingCategory'].presence,
        supplier_url: nil,
        image_url: product['ProductImageUrlThumbnail'].presence
      }
    end

    # The order id to act on: the draft created/used during this scraper's
    # add_to_cart if any, else the account's active order (or the no-active-order
    # sentinel, which UpdateOrderEntryDetail auto-promotes to a real draft).
    def active_order_id!
      @active_draft_id || api_client.account_context[:order_entry_header_id]
    end

    # Tally quantities by SKU. Keys normalized to strings; quantities summed so
    # duplicate lines for the same SKU compare correctly.
    def tally_by_sku(rows)
      rows.each_with_object(Hash.new(0)) do |row, acc|
        sku = row[:sku].to_s.strip
        next if sku.blank?

        acc[sku] += row[:quantity].to_i
      end
    end

    # A real, syncable order guide: a concrete named/owned list, not the
    # all-zeros-GUID system list PFG returns alongside it.
    ZERO_GUID = '00000000-0000-0000-0000-000000000000'
    def order_guide_header?(header)
      id = header['ProductListHeaderId'].to_s
      id.present? && id != ZERO_GUID
    end

    def product_display_name(product)
      [product['ProductBrand'].presence, product['ProductDescription']].compact.join(' - ')
    end

    def product_pack_size(product)
      uom = Array(product['UnitOfMeasureOrderQuantities']).first || {}
      [uom['PackSize'], uom['UnitOfMeasureAbbreviation']].compact.join(' ').presence
    end

    # CRITICAL — catch-weight pricing: for a catch-weight case UOM, PFG's Price
    # is the PER-POUND price, not the case price (e.g. $1.64/lb for a ~39 lb
    # case). Storing it raw would make PFG look ~40x cheaper than reality and
    # corrupt every savings comparison. The UOM-level ProductIsCatchWeight flag
    # is authoritative (the top-level flag is always false); when set, the case
    # price is Price x ProductAverageWeight. Non-catch-weight Price is already
    # the case price. Shared by catalog and order-guide mapping.
    def case_price_for(product, prices)
      uom = Array(product['UnitOfMeasureOrderQuantities']).first || {}
      raw_price = prices[product['ProductKey'].to_s]
      return raw_price unless raw_price

      avg_weight = uom['ProductAverageWeight'].to_f
      if uom['ProductIsCatchWeight'] && avg_weight.positive?
        (raw_price * avg_weight).round(2)
      else
        raw_price
      end
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
