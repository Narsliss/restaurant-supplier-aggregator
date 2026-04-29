module Scrapers
  class SyscoScraper < BaseScraper
    BASE_URL = 'https://shop.sysco.com'.freeze
    LOGIN_URL = 'https://secure.sysco.com/'.freeze
    CATALOG_URL = 'https://shop.sysco.com/app/catalog'.freeze
    LISTS_URL = 'https://shop.sysco.com/app/lists'.freeze
    ORDER_MINIMUM = 0.00 # No confirmed minimum — Sysco minimums vary by account
    PRODUCTS_PER_PAGE = 24
    MAX_PAGES_PER_TERM = 5
    GRAPHQL_URL = 'https://gateway-api.shop.sysco.com/graphql'.freeze

    LOGGED_IN_SELECTORS = [
      "a[href*='account']", "a[href*='logout']", "a[href*='sign-out']",
      '.account-menu', '.user-nav', '.user-menu',
      "[data-testid='user-menu']", "[data-testid='account']",
      "button[aria-label*='account']", "button[aria-label*='Account']"
    ].freeze

    # ----------------------------------------------------------------
    # Browser setup — stealth mode (Sysco is enterprise-scale, expect WAF)
    # ----------------------------------------------------------------

    def with_browser
      if @browser
        # Browser already open (nested call) — reuse without closing
        yield(@browser)
      else
        @browser = Ferrum::Browser.new(**build_stealth_browser_opts)
        setup_network_interception(@browser)
        inject_stealth_scripts(@browser)

        begin
          yield(@browser)
        ensure
          @browser&.quit
          @browser = nil
        end
      end
    end

    # ----------------------------------------------------------------
    # Public API — Authentication
    # ----------------------------------------------------------------

    def login
      with_browser do
        if restore_session && logged_in?
          logger.info '[Sysco] Session restored successfully'
          save_session
          return true
        end

        perform_login_steps
        sleep 3

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          diagnose_login_failure
          raise AuthenticationError, 'Login completed but not authenticated'
        end
      end
    end

    def logged_in?
      current_url = begin
        browser.current_url.to_s
      rescue StandardError
        ''
      end

      # Must be on the shop.sysco.com/app SPA (not the auth/login page)
      return false unless current_url.include?('shop.sysco.com/app')
      return false if current_url.include?('auth/')

      # Check multiple signals — the MSS_STATEFUL cookie takes time to be set
      # by the SPA after a redirect, so also check for authenticated UI elements.
      role = extract_mss_role
      if role && role != 'GUEST' && role != 'none' && role != 'error'
        logger.info "[Sysco] Authenticated with role=#{role}"
        return true
      end

      # Fallback: check for authenticated-only UI elements that guests don't see.
      # "View Cart and Checkout" and account menu only appear for logged-in users.
      auth_selectors = [
        "button[aria-label*='account']", "button[aria-label*='Account']",
        "[data-testid='user-menu']", "[data-testid='account']",
        "a[href*='account']", '.account-menu', '.user-nav',
        "button:has-text('Cart')"
      ]
      has_auth_ui = auth_selectors.any? do |sel|
        browser.at_css(sel)
      rescue StandardError
        false
      end

      # Also check page content for authenticated indicators
      has_auth_ui ||= begin
        body = browser.evaluate("document.body?.innerText?.substring(0, 1000)") rescue ''
        body.include?('View Cart') || body.include?('My Orders') || body.include?('Sign Out')
      end

      if has_auth_ui
        logger.info "[Sysco] Authenticated (UI elements present, role=#{role || 'pending'})"
        return true
      end

      logger.info "[Sysco] URL looks authenticated but role=#{role} and no auth UI — NOT logged in"
      false
    end

    def extract_mss_role
      browser.evaluate(<<~JS)
        (function() {
          var c = document.cookie;
          var m = c.match(/MSS_STATEFUL=([^;]+)/);
          if (!m) return 'none';
          try {
            var decoded = decodeURIComponent(m[1]);
            var obj = JSON.parse(decoded);
            var parts = obj.token.split('.');
            var payload = JSON.parse(atob(parts[1]));
            return payload.role || 'unknown';
          } catch(e) { return 'error'; }
        })()
      JS
    rescue StandardError
      'error'
    end

    def soft_refresh
      # API-based: check if stored JWT is still valid by making a lightweight call
      return false unless api_session_valid?

      # Verify the token actually works with a real API call
      tokens = load_api_tokens
      test_data = graphql_request('GetLists', get_lists_query, {
        listTypes: %w[MY_LIST],
        includeItemsCount: false
      })

      if test_data.dig('data', 'getLists')
        credential.touch(:last_login_at)
        logger.info '[Sysco] Soft refresh successful — API token is valid'
        true
      else
        logger.info '[Sysco] Soft refresh failed — API token rejected'
        false
      end
    rescue StandardError => e
      logger.warn "[Sysco] Soft refresh error: #{e.class}: #{e.message}"
      false
    end

    # Ensures the browser is logged in. Tries profile-based session restore
    # first, falls back to full login. Assumes @browser is already set.
    # Used by SyscoCombinedImportJob to login once and reuse the session.
    def ensure_logged_in
      # With incognito: false + persistent profile, Chrome loads cookies from
      # disk automatically. Just navigate and check if the session is valid.
      if restore_session
        logger.info '[Sysco] Already logged in (persistent profile cookies valid)'
      else
        logger.info '[Sysco] Profile session expired, performing fresh login...'
        perform_login_steps
        sleep 3
        unless logged_in?
          begin
            browser.goto("#{BASE_URL}/app")
          rescue Ferrum::PendingConnectionsError
            nil
          end
          sleep 3
          raise AuthenticationError, 'Could not log in' unless logged_in?
        end
        credential.mark_active!
      end
      dismiss_promo_modals
    end

    # ----------------------------------------------------------------
    # Public API — Catalog Search (via GraphQL API — no browser needed)
    # ----------------------------------------------------------------

    TERMS_PER_BROWSER_SESSION = 20 # Legacy — kept for compatibility

    def scrape_catalog(search_terms, max_per_term: 100, &on_batch)
      ensure_api_session!

      results = []
      seen_skus = Set.new

      search_terms.each_with_index do |term, idx|
        begin
          logger.info "[Sysco] Searching catalog via API for: #{term} (#{idx + 1}/#{search_terms.size})"
          products = search_supplier_catalog(term, max: max_per_term)

          new_products = products.reject { |p| seen_skus.include?(p[:supplier_sku]) }
          new_products.each { |p| seen_skus.add(p[:supplier_sku]) }

          if new_products.any?
            logger.info "[Sysco] Found #{new_products.size} new products for '#{term}' (#{products.size - new_products.size} dupes)"
            if block_given?
              yield(new_products)
            else
              results.concat(new_products)
            end
          else
            logger.info "[Sysco] No new products for '#{term}'"
          end
        rescue StandardError => e
          logger.error "[Sysco] Error searching '#{term}': #{e.class}: #{e.message}"
        end
      end

      logger.info "[Sysco] Catalog scrape complete: #{seen_skus.size} total unique products"
      results
    end

    # Refresh pricing for a list of known Sysco product IDs via the getProducts
    # GraphQL endpoint (direct ID lookup — no keyword search). This is the
    # complement to scrape_catalog: term-search discovers NEW SKUs, this
    # refreshes EXISTING SKUs that don't match any of the generic search terms.
    #
    # Yields per-batch results so callers can write incrementally:
    #   { updates: [{supplier_sku:, current_price:, price_unit:}, ...],
    #     missed: [sku_string, ...] }
    #
    # SKUs in `missed` either weren't returned by the API or returned no price —
    # treat them as candidates for consecutive_misses tracking.
    REFRESH_BATCH_SIZE = 30

    def refresh_known_skus(skus, batch_size: REFRESH_BATCH_SIZE)
      ensure_api_session!
      tokens = load_api_tokens

      total_updated = 0
      total_missed = 0
      batch_count = 0

      skus.each_slice(batch_size) do |batch|
        batch_count += 1

        begin
          updates, missed = refresh_batch(batch, tokens)
        rescue StandardError => e
          logger.error "[Sysco] Refresh batch ##{batch_count} failed: #{e.class}: #{e.message}"
          updates = []
          missed = batch.map(&:to_s)
        end

        total_updated += updates.size
        total_missed += missed.size

        if (batch_count % 20).zero?
          logger.info "[Sysco] Refresh progress: batch #{batch_count}, updated=#{total_updated}, missed=#{total_missed}"
        end

        yield(updates: updates, missed: missed) if block_given?
      end

      logger.info "[Sysco] Refresh complete: #{total_updated} updated, #{total_missed} missed across #{batch_count} batches"
      { updated: total_updated, missed: total_missed, batches: batch_count }
    end

    def refresh_batch(batch, tokens)
      product_params = batch.map do |sku|
        {
          productId: sku.to_s,
          sellerId: tokens[:seller_id],
          siteId: tokens[:site_id],
          quantity: { case: 0, each: 0 },
          splitCode: 'CASE'
        }
      end

      data = graphql_request('Prices', prices_query, {
        isIncludePriceInfoV2: true,
        products: { params: product_params },
        priceOptions: {}
      })

      response_products = data.dig('data', 'getProducts') || []
      response_by_id = response_products.index_by { |p| p['productId'].to_s }

      updates = []
      missed = []

      batch.each do |sku|
        sku_str = sku.to_s
        pp = response_by_id[sku_str]

        # SKU not in API response at all → genuine miss (likely removed upstream)
        if pp.nil?
          missed << sku_str
          next
        end

        # SKU returned by API → counts as "seen" even if no price.
        # Matches catalog scrape semantics (returned-from-search = not missed).
        case_info = pp.dig('priceInfoV2', 'case') || {}
        each_info = pp.dig('priceInfoV2', 'each') || {}
        current_price = case_info['netPrice'] || case_info['price'] ||
                        each_info['netPrice'] || each_info['price']

        price_unit = if case_info['netPrice'] || case_info['price']
                       'CS'
                     elsif each_info['netPrice'] || each_info['price']
                       'EA'
                     end

        updates << {
          supplier_sku: sku_str,
          current_price: current_price&.to_f,
          price_unit: price_unit
        }
      end

      [updates, missed]
    end

    def search_supplier_catalog(term, max: 100)
      products = []
      start = 0
      num = PRODUCTS_PER_PAGE

      loop do
        break if products.size >= max

        # Search products via GraphQL API
        search_data = graphql_search_products(term, start: start, num: num)
        break unless search_data

        total_results = search_data.dig('metaInfo', 'totalResults') || 0
        results = search_data['results'] || []
        break if results.empty?

        # Get pricing for these products
        price_map = graphql_get_prices(results)

        # Convert to BaseScraper product hash format
        results.each do |result|
          product = parse_search_result(result, price_map)
          products << product if product
        end

        logger.info "[Sysco] API search '#{term}': got #{results.size} products (#{products.size}/#{total_results} total)"

        # Log first product as a sample for monitoring
        if products.size == results.size && products.any?
          sample = products.first
          logger.info "[Sysco] Sample: SKU=#{sample[:supplier_sku]}, name=#{sample[:supplier_name]&.first(60)}, price=#{sample[:current_price]} #{sample[:price_unit]}, pack=#{sample[:pack_size]}"
        end

        start += num
        break if start >= total_results
        break if start >= max
        break if (start / num) >= MAX_PAGES_PER_TERM
      end

      products.first(max)
    end

    # Legacy browser-based SPA search — kept for login token capture flow
    def perform_spa_search(term)
      searched = browser.evaluate(<<~JS)
        (function() {
          var selectors = [
            'input[type="search"]', 'input[placeholder*="Search"]',
            'input[placeholder*="search"]', 'input[aria-label*="Search"]',
            'input[aria-label*="search"]', 'input[data-testid*="search"]',
            'input[name="q"]', 'input[name="search"]',
            'input[class*="search"]', '[class*="search"] input',
            '[class*="Search"] input'
          ];
          var input = null;
          for (var i = 0; i < selectors.length; i++) {
            var el = document.querySelector(selectors[i]);
            if (el && el.offsetHeight > 0) { input = el; break; }
          }
          if (!input) return 'no_input';
          input.focus();
          var nativeSetter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value'
          ).set;
          nativeSetter.call(input, '');
          input.dispatchEvent(new Event('input', { bubbles: true }));
          nativeSetter.call(input, #{term.to_json});
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
          return 'filled';
        })()
      JS
      return false if searched == 'no_input'

      sleep 0.5
      browser.keyboard.type(:Enter)
      sleep 3
      logger.info "[Sysco] After SPA search for '#{term}': URL = #{browser.current_url rescue ''}"
      sleep 2
      true
    rescue StandardError => e
      logger.warn "[Sysco] SPA search error: #{e.class}: #{e.message}"
      false
    end

    # ----------------------------------------------------------------
    # Public API — List / Order Guide Scraping (via GraphQL API)
    # ----------------------------------------------------------------

    def scrape_lists
      ensure_api_session!
      scrape_supplier_lists
    end

    def scrape_supplier_lists
      logger.info '[Sysco] Fetching lists via GraphQL API...'

      tokens = load_api_tokens
      seller_id = tokens[:seller_id]
      site_id = tokens[:site_id]

      # Fetch list metadata
      lists_data = graphql_request('GetLists', get_lists_query, {
        listTypes: %w[MY_LIST SHARED_LIST FAVORITE_LIST],
        includeItemsCount: false
      })

      raw_lists = lists_data.dig('data', 'getLists') || []
      logger.info "[Sysco] Found #{raw_lists.size} lists via API"

      lists = []
      raw_lists.each do |list_meta|
        begin
          list_name = list_meta['name'].to_s.strip
          next if list_name.blank?

          list_id = list_meta['listId']
          list_type = list_meta['listType']
          logger.info "[Sysco] Fetching items for list: #{list_name} (#{list_id}, type=#{list_type})"

          # Fetch items for this list
          items = graphql_get_list_items(
            list_id: list_id,
            list_type: list_type,
            seller_id: list_meta['sellerId'] || seller_id,
            site_id: list_meta['siteId'] || site_id
          )

          logger.info "[Sysco] Got #{items.size} items from '#{list_name}'"

          lists << {
            name: list_name,
            remote_id: list_id,
            url: LISTS_URL,
            list_type: 'custom',
            items: items
          }
        rescue StandardError => e
          logger.error "[Sysco] Error fetching list '#{list_meta['name']}': #{e.class}: #{e.message}"
        end
      end

      lists
    end

    # ----------------------------------------------------------------
    # Public API — Ordering (out of scope)
    # ----------------------------------------------------------------

    # Fetch live prices for a list of Sysco product SKUs via GraphQL API.
    # Returns: [{ supplier_sku:, current_price:, in_stock:, supplier_name: }, ...]
    def scrape_prices(product_skus)
      ensure_api_session!
      tokens = load_api_tokens
      product_skus = normalize_price_queries(product_skus).map { |q| q[:sku] }

      logger.info "[Sysco] Fetching live prices for #{product_skus.size} SKUs via API"

      # Build product params for the Prices query
      product_params = product_skus.map do |sku|
        {
          productId: sku.to_s,
          sellerId: tokens[:seller_id],
          siteId: tokens[:site_id],
          quantity: { case: 0, each: 0 },
          splitCode: 'CASE'
        }
      end

      # Batch in groups of 50 (API may have limits)
      results = []
      product_params.each_slice(50) do |batch|
        data = graphql_request('Prices', prices_query, {
          isIncludePriceInfoV2: true,
          products: { params: batch },
          priceOptions: {}
        })

        price_products = data.dig('data', 'getProducts') || []
        price_products.each do |pp|
          product_id = pp['productId'].to_s
          case_price_info = pp.dig('priceInfoV2', 'case') || {}
          each_price_info = pp.dig('priceInfoV2', 'each') || {}

          current_price = case_price_info['netPrice'] || case_price_info['price'] ||
                          each_price_info['netPrice'] || each_price_info['price']

          next unless current_price

          results << {
            supplier_sku: product_id,
            current_price: current_price.to_f,
            in_stock: true, # If the API returns a price, it's available
            supplier_name: pp.dig('productInfo', 'name') || product_id
          }
        end
      end

      logger.info "[Sysco] Got live prices for #{results.size}/#{product_skus.size} SKUs"
      results
    end

    # Add items to a Sysco draft order via GraphQL API.
    # Items format: [{ sku: "7203474", name: "Chicken Breast", quantity: 2, expected_price: 63.10 }]
    # Returns: { added: count, failed: [{ sku:, name:, error: }], order_id: uuid }
    def add_to_cart(items, delivery_date: nil)
      ensure_api_session!
      tokens = load_api_tokens

      logger.info "[Sysco] Adding #{items.size} items to cart via API"

      # Step 1: Create a draft order
      order_name = Time.current.strftime('%b %d %Y %I:%M %p')
      order = graphql_create_order(name: order_name, delivery_date: delivery_date)
      order_id = order['id']
      sequence_id = order['sequenceId'] || 1
      logger.info "[Sysco] Created draft order: #{order_id} (#{order_name})"

      # Cache the order metadata we need to echo back to submitOrderV2
      @last_sysco_order_name = order_name
      @last_sysco_delivery_ms = if delivery_date
                                  (delivery_date.to_time.to_f * 1000).to_i
                                end

      # Step 2: Add items in a single UpdateOrder call.
      # Send ONLY the identifying fields — no pricingType, no price, no
      # totalPrice, no commissionBasis. Sysco's updateOrderV2 computes
      # the authoritative values server-side based on the account's
      # current pricing tier (list, contract, deal, promo, etc.) and
      # returns them on the response. Hardcoding pricingType: "N" here
      # was silently overridden by the server for contract items but
      # also prevented submit from validating properly. Matches the
      # shape Sysco's own web frontend sends for contract-priced items.
      line_items = items.map do |item|
        {
          qty: item[:quantity].to_i,
          soldAs: 'cs',
          productId: item[:sku].to_s,
          siteId: tokens[:site_id],
          sellerId: tokens[:seller_id]
        }
      end

      added_items = []
      failed_items = []

      begin
        updated = graphql_update_order(
          order_id: order_id,
          sequence_id: sequence_id,
          line_items: line_items
        )

        # Verify which items made it onto the order
        order_product_ids = (updated['lineItems'] || []).map { |li| li['productId'].to_s }
        items.each do |item|
          if order_product_ids.include?(item[:sku].to_s)
            added_items << item
            logger.info "[Sysco] Added SKU #{item[:sku]} qty #{item[:quantity]}"
          else
            failed_items << { sku: item[:sku], name: item[:name], error: 'Not found on order after add' }
            logger.warn "[Sysco] SKU #{item[:sku]} not found on order after add"
          end
        end

        @last_sysco_order_id = order_id
        @last_sysco_sequence_id = updated['sequenceId'] || sequence_id
        # Cache minimal line items for submit. We intentionally DO NOT
        # cache price/pricingType/totalPrice — submit has stricter
        # validation than update and rejects our echoed values
        # ("pricingType [N] is not compatible with price [X]"). Let
        # Sysco's submit validator pull authoritative pricing from the
        # stored draft state instead.
        @last_sysco_line_items = (updated['lineItems'] || []).map do |li|
          {
            qty: li['qty'],
            soldAs: 'cs', # input enum is lowercase, response is "CASE"
            productId: li['productId'].to_s,
            siteId: tokens[:site_id],
            sellerId: tokens[:seller_id]
          }
        end
      rescue StandardError => e
        logger.error "[Sysco] Failed to add items to order: #{e.message}"
        # Clean up the empty draft order
        begin
          graphql_delete_order(order_id)
          logger.info "[Sysco] Cleaned up draft order #{order_id}"
        rescue StandardError => del_err
          logger.warn "[Sysco] Could not clean up draft order: #{del_err.message}"
        end
        raise ScrapingError, "Failed to add items to Sysco cart: #{e.message}"
      end

      if failed_items.any? && added_items.empty?
        # All items failed — clean up the order
        begin
          graphql_delete_order(order_id)
        rescue StandardError
          nil
        end
        raise ScrapingError, "Failed to add any items to Sysco order. " \
          "SKUs: #{failed_items.map { |f| f[:sku] }.join(', ')}"
      end

      logger.info "[Sysco] Cart ready: #{added_items.size} items, #{failed_items.size} failed, order=#{order_id}"
      { added: added_items.size, failed: failed_items, order_id: order_id }
    end

    # Remove individual items from the current draft order by setting qty to 0.
    # Accepts an array of SKU strings, e.g. ['7216861', '6040760']
    def remove_from_cart(skus)
      ensure_api_session!
      tokens = load_api_tokens

      order_id = @last_sysco_order_id
      sequence_id = @last_sysco_sequence_id
      raise ScrapingError, 'No draft order — call add_to_cart first' unless order_id

      skus = Array(skus).map(&:to_s)
      logger.info "[Sysco] Removing #{skus.size} item(s) from order #{order_id}: #{skus.join(', ')}"

      line_items = skus.map do |sku|
        {
          qty: 0,
          soldAs: 'cs',
          productId: sku,
          pricingType: 'N',
          price: 0,
          totalPrice: 0,
          commissionBasis: 0,
          siteId: tokens[:site_id],
          sellerId: tokens[:seller_id]
        }
      end

      updated = graphql_update_order(
        order_id: order_id,
        sequence_id: sequence_id,
        line_items: line_items
      )

      @last_sysco_sequence_id = updated['sequenceId'] || sequence_id

      remaining = (updated['lineItems'] || []).map { |li| li['productId'].to_s }
      removed = skus.select { |sku| !remaining.include?(sku) }
      still_present = skus.select { |sku| remaining.include?(sku) }

      if still_present.any?
        logger.warn "[Sysco] #{still_present.size} item(s) still on order after removal: #{still_present.join(', ')}"
      end

      logger.info "[Sysco] Removed #{removed.size}/#{skus.size} items. Order now has #{updated['totalLineItems']} items, total=#{updated['totalPrice']}"

      {
        removed: removed,
        still_present: still_present,
        remaining_items: updated['totalLineItems'],
        total_price: updated['totalPrice']
      }
    end

    # Clear the Sysco cart by deleting the draft order.
    def clear_cart
      ensure_api_session!

      # If we have a tracked order from add_to_cart, delete it
      if @last_sysco_order_id
        logger.info "[Sysco] Deleting draft order #{@last_sysco_order_id}"
        graphql_delete_order(@last_sysco_order_id)
        @last_sysco_order_id = nil
        @last_sysco_sequence_id = nil
        return
      end

      # Otherwise find and delete any open draft orders we created
      orders = graphql_get_open_orders
      draft_orders = orders.select { |o| o['status'] == 'OPEN' && o['orderSource'] == 'WEB' }
      if draft_orders.any?
        draft_orders.each do |order|
          logger.info "[Sysco] Deleting draft order #{order['id']} (#{order['name']})"
          graphql_delete_order(order['id'])
        end
      else
        logger.info '[Sysco] No draft orders to clear'
      end
    end

    def checkout(dry_run: false)
      logger.info "[Sysco] checkout starting (dry_run=#{dry_run})"
      ensure_api_session!

      # Verify we have a draft order from add_to_cart
      order_id = @last_sysco_order_id
      sequence_id = @last_sysco_sequence_id
      raise ScrapingError, 'No draft order — call add_to_cart first' unless order_id

      # Get current order state for totals
      orders = graphql_get_open_orders
      current_order = orders.find { |o| o['id'] == order_id }

      order_total = current_order&.dig('totalPrice')
      item_count = current_order&.dig('totalLineItems')
      delivery_date_raw = current_order&.dig('deliveryDate') # epoch ms (int) OR ISO string

      # Convert to date string — handle both epoch-ms integer and ISO string
      delivery_str = if delivery_date_raw.nil? || delivery_date_raw == ''
                       nil
                     elsif delivery_date_raw.is_a?(Numeric)
                       Time.at(delivery_date_raw / 1000).strftime('%b %d, %Y')
                     elsif delivery_date_raw.is_a?(String) && delivery_date_raw.match?(/\A\d+\z/)
                       # Numeric string — treat as epoch ms
                       Time.at(delivery_date_raw.to_i / 1000).strftime('%b %d, %Y')
                     else
                       # ISO date string like "2026-04-13"
                       begin
                         Date.parse(delivery_date_raw.to_s).strftime('%b %d, %Y')
                       rescue ArgumentError
                         logger.warn "[Sysco] Could not parse deliveryDate=#{delivery_date_raw.inspect}"
                         nil
                       end
                     end

      logger.info "[Sysco] Order #{order_id}: #{item_count} items, total=#{order_total}, delivery=#{delivery_str}"

      raise ScrapingError, 'Cart is empty' if item_count.nil? || item_count == 0

      # Validate delivery date is currently bookable. Sysco's submitOrderV2
      # rejects with the opaque "The given delivery date is invalid" when
      # the account's cutoff has passed or the date isn't on the route.
      # Surface a clearer error before we hit submit.
      available_days = graphql_available_delivery_days(shipping_condition: 0)
      if available_days.any?
        draft_date_iso = if delivery_date_raw.is_a?(Numeric)
                           Time.at(delivery_date_raw / 1000).utc.strftime('%Y-%m-%d')
                         elsif delivery_date_raw.is_a?(String) && !delivery_date_raw.empty?
                           begin
                             Date.parse(delivery_date_raw).strftime('%Y-%m-%d')
                           rescue ArgumentError
                             nil
                           end
                         end
        logger.info "[Sysco] Draft delivery date=#{draft_date_iso.inspect}, available=#{available_days.first(5).inspect}..."
        if draft_date_iso && !available_days.include?(draft_date_iso)
          earliest = available_days.first
          raise DeliveryUnavailableError,
                "Sysco is not accepting delivery on #{draft_date_iso} for this account. " \
                "Earliest currently-available date is #{earliest}. " \
                "Available: #{available_days.first(5).join(', ')}#{available_days.size > 5 ? '...' : ''}."
        end
      else
        logger.warn "[Sysco] Could not fetch availableDays — skipping pre-submit date validation"
      end

      # Check order minimum
      if order_total && order_total > 0 && order_total < ORDER_MINIMUM
        raise OrderMinimumError.new(
          'Order minimum not met',
          minimum: ORDER_MINIMUM,
          current_total: order_total
        )
      end

      # ═══════════════════════════════════════════
      # ═══ SAFETY GATE — DRY RUN CHECK ══════════
      # ═══════════════════════════════════════════
      if dry_run
        logger.info "[Sysco] DRY RUN COMPLETE — stopping before submit"
        logger.info "[Sysco] Would have submitted order #{order_id}: total=#{order_total}"

        return {
          confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
          total: order_total,
          delivery_date: delivery_str,
          dry_run: true,
          cart_items: [],
          checkout_summary: { order_id: order_id, total: order_total, item_count: item_count }
        }
      end

      # ═══════════════════════════════════════════
      # ═══ LIVE ORDER — Submit via API ═══════════
      # ═══════════════════════════════════════════
      logger.warn "[Sysco] PLACING LIVE ORDER — submitting order #{order_id}"
      result = graphql_submit_order(order_id: order_id, sequence_id: sequence_id)

      logger.warn "[Sysco] RAW submitOrderV2 response: #{result.inspect}"

      # submitOrderV2 only returns __typename (see submit_order_mutation comment).
      # Look up the submitted order via getOrderHeadersForAccounts to get the
      # confirmation number and final total.
      submitted_order = nil
      begin
        all_orders = graphql_get_open_orders
        submitted_order = all_orders.find { |o| o['id'] == order_id }
        logger.info "[Sysco] Post-submit order lookup: #{submitted_order.inspect}"
      rescue StandardError => e
        logger.warn "[Sysco] Could not look up submitted order details: #{e.message}"
      end

      confirmation = submitted_order&.dig('name') ||
                     submitted_order&.dig('id') ||
                     order_id ||
                     "SYSCO-#{Time.current.strftime('%Y%m%d%H%M%S')}"
      submitted_total = submitted_order&.dig('totalPrice') || order_total

      logger.info "[Sysco] Order submitted: #{confirmation}"

      @last_sysco_order_id = nil
      @last_sysco_sequence_id = nil

      {
        confirmation_number: confirmation,
        total: submitted_total,
        delivery_date: delivery_str
      }
    end

    # Public wrapper for delivery date fetching (used by SyscoCombinedImportJob)
    def fetch_available_delivery_days(shipping_condition: 0)
      graphql_available_delivery_days(shipping_condition: shipping_condition)
    end

    private

    # ----------------------------------------------------------------
    # Login flow — hybrid password + optional MFA
    # ----------------------------------------------------------------

    def perform_login_steps
      logger.info "[Sysco] Starting login for #{credential.username}"

      # Step 1: Navigate to Sysco's authentication portal
      navigate_to(LOGIN_URL)
      sleep 3
      apply_stealth

      # Check if cookies auto-redirected us past the login form (session was already valid)
      current = browser.current_url rescue ''
      if current.include?('shop.sysco.com/app') && !current.include?('auth/')
        logger.info "[Sysco] Login successful — cookies auto-authenticated (redirected to #{current})"
        return
      end

      log_page_state('After navigating to login page')

      # Step 2: Find and fill the email/username field
      email_filled = fill_login_email
      unless email_filled
        # Double-check: maybe the page redirected while we were looking for the field
        current = browser.current_url rescue ''
        if current.include?('shop.sysco.com/app') && !current.include?('auth/')
          logger.info "[Sysco] Login successful — auto-redirected during email step (#{current})"
          return
        end
        diagnose_login_failure
        raise AuthenticationError, 'Could not find or fill email field on secure.sysco.com'
      end
      logger.info '[Sysco] Email entered, clicking Next...'
      sleep 1

      # Step 2b: Click "Next" to advance past the email step
      click_next_button
      logger.info '[Sysco] Next clicked, waiting for password field...'
      sleep 3

      # Step 3: Fill password field (appears via JavaScript after email)
      password_filled = fill_login_password
      unless password_filled
        # Check if clicking Next auto-completed login (e.g., SSO or cookie-based)
        current = browser.current_url rescue ''
        if current.include?('shop.sysco.com/app') && !current.include?('auth/')
          logger.info "[Sysco] Login successful — auto-completed after email step (#{current})"
          return
        end
        diagnose_login_failure
        raise AuthenticationError, 'Password field did not appear after entering email'
      end
      logger.info '[Sysco] Password entered'

      # Step 4: Check for "remember me" and submit
      check_remember_me
      click_login_submit
      logger.info '[Sysco] Login form submitted, waiting for response...'
      sleep 5

      # Step 5: Check what happened — success, MFA, second login, or error
      log_page_state('After first login submit')

      # Check if we're already logged in (no MFA, no second login)
      if logged_in?
        logger.info '[Sysco] Login successful (no MFA)'
        dismiss_promo_modals
        return
      end

      # Check for login errors before proceeding
      detect_login_errors

      # Check for MFA prompt (optional — some Sysco accounts have it, some don't)
      if handle_mfa_if_prompted
        logger.info '[Sysco] MFA completed successfully'
        sleep 3
        wait_for_post_login_redirect
        return
      end

      # Step 6: Handle second login page (shop.sysco.com/auth/login)
      # secure.sysco.com often redirects to shop.sysco.com/auth/login
      # which presents its own email + password form.
      current_url = browser.current_url rescue ''
      if current_url.include?('shop.sysco.com/auth/login') || current_url.include?('/auth/')
        logger.info "[Sysco] Redirected to second login page: #{current_url}"
        sleep 2
        log_page_state('Second login page')

        email_filled = fill_login_email
        if email_filled
          logger.info '[Sysco] Second login — email entered, clicking Next...'
          sleep 1

          click_next_button
          logger.info '[Sysco] Second login — Next clicked, waiting for password...'
          sleep 3

          password_filled = fill_login_password
          if password_filled
            logger.info '[Sysco] Second login — password entered'
            check_remember_me
            click_login_submit
            logger.info '[Sysco] Second login submitted, waiting...'
            sleep 5
            log_page_state('After second login submit')
          end
        end
      end

      # Final check — should be logged in now
      sleep 3 unless logged_in?
      if logged_in?
        logger.info '[Sysco] Login successful'
        dismiss_promo_modals
        return
      end

      # Still not logged in — something went wrong
      diagnose_login_failure
      raise AuthenticationError, 'Login failed — not authenticated after both login stages'
    end

    # ----------------------------------------------------------------
    # Promo modal dismissal
    # ----------------------------------------------------------------

    def dismiss_promo_modals
      dismissed = browser.evaluate(<<~JS)
        (function() {
          // Try common close button patterns for the "Save a bunch!" modal
          var selectors = [
            'button[aria-label="Close"]',
            'button[aria-label="close"]',
            'button[aria-label="Close dialog"]',
            'button.close',
            '.modal-close',
            '[class*="modal"] button[class*="close"]',
            '[class*="modal"] button[class*="Close"]',
            '[class*="dialog"] button[class*="close"]',
            '[class*="overlay"] button[class*="close"]',
            '[class*="popup"] button[class*="close"]',
            '[class*="promo"] button[class*="close"]',
            '[class*="banner"] button[class*="close"]',
            '[role="dialog"] button[aria-label="Close"]',
            '[role="dialog"] button',
            'button[class*="dismiss"]',
            'button[class*="Dismiss"]'
          ];
          for (var i = 0; i < selectors.length; i++) {
            var btn = document.querySelector(selectors[i]);
            if (btn && btn.offsetHeight > 0) { btn.click(); return 'selector:' + selectors[i]; }
          }

          // Look for close icons (SVG or icon fonts) inside buttons near modals/overlays
          var allButtons = document.querySelectorAll('button, [role="button"]');
          for (var i = 0; i < allButtons.length; i++) {
            var btn = allButtons[i];
            if (!btn.offsetHeight) continue;
            var text = (btn.innerText || '').trim();

            // Match × X ✕ ✖ or empty buttons with SVG close icons
            if (text === '×' || text === 'X' || text === '✕' || text === '✖') {
              btn.click();
              return 'x_button';
            }

            // Empty button with SVG (likely a close icon) inside a modal/overlay
            if (text === '' && btn.querySelector('svg') && btn.closest('[class*="modal"], [class*="dialog"], [class*="overlay"], [class*="popup"], [role="dialog"]')) {
              btn.click();
              return 'svg_close_icon';
            }
          }

          // Try "No thanks", "Not now", "Close", "Got it" text buttons in modals
          var dismissTexts = ['no thanks', 'not now', 'close', 'got it', 'dismiss', 'maybe later', 'skip'];
          for (var i = 0; i < allButtons.length; i++) {
            var btn = allButtons[i];
            if (!btn.offsetHeight) continue;
            var text = (btn.innerText || '').trim().toLowerCase();
            for (var j = 0; j < dismissTexts.length; j++) {
              if (text === dismissTexts[j] || text.indexOf(dismissTexts[j]) !== -1) {
                btn.click();
                return 'dismiss_text:' + text;
              }
            }
          }

          // Try clicking the backdrop/overlay behind the modal
          var overlays = document.querySelectorAll('[class*="overlay"], [class*="backdrop"], [class*="Overlay"], [class*="Backdrop"]');
          for (var i = 0; i < overlays.length; i++) {
            if (overlays[i].offsetHeight > 0) { overlays[i].click(); return 'overlay'; }
          }

          return false;
        })()
      JS

      if dismissed
        logger.info "[Sysco] Dismissed promo modal via: #{dismissed}"
        sleep 1
      else
        # Last resort: try pressing Escape key to dismiss any modal
        browser.keyboard.type(:Escape)
        sleep 0.5
        logger.debug '[Sysco] Sent Escape key as modal dismiss fallback'
      end
    rescue StandardError => e
      logger.debug "[Sysco] No promo modal to dismiss: #{e.message}"
    end

    # ----------------------------------------------------------------
    # Catalog search helpers
    # ----------------------------------------------------------------

    # Kill the current browser and open a fresh one. This is the only reliable
    # way to reclaim memory from Sysco's SPA which accumulates hundreds of MB
    # of DOM nodes per search. Session restore after restart takes ~3s.
    def restart_browser!
      logger.info '[Sysco] Restarting browser to free memory...'
      @browser&.quit rescue nil
      @browser = Ferrum::Browser.new(**build_stealth_browser_opts)
      setup_network_interception(@browser)
      inject_stealth_scripts(@browser)
    rescue StandardError => e
      logger.error "[Sysco] Browser restart failed: #{e.class}: #{e.message}"
      @browser = nil
      raise
    end

    # Clear accumulated DOM nodes and detached elements to free memory.
    # SPAs like Sysco's shop accumulate product cards, images, and event
    # listeners across page navigations — this strips them out after we've
    # already extracted the data we need.
    def cleanup_browser_memory
      browser.evaluate(<<~JS)
        (function() {
          // Remove all images (biggest memory consumers) — we already extracted text data
          document.querySelectorAll('img, picture, source, video, svg[class*="product"]').forEach(function(el) {
            el.remove();
          });

          // Clear any detached iframes
          document.querySelectorAll('iframe').forEach(function(el) { el.remove(); });

          // Nullify large data attributes
          document.querySelectorAll('[data-src], [data-srcset]').forEach(function(el) {
            el.removeAttribute('data-src');
            el.removeAttribute('data-srcset');
          });

          // Trigger garbage collection if exposed
          if (window.gc) window.gc();
        })()
      JS
    rescue StandardError => e
      logger.debug "[Sysco] DOM cleanup skipped: #{e.message}"
    end

    # Wait for a CSS selector to appear on the page
    def wait_for_selector(selector, timeout: 10)
      timeout.times do
        found = browser.evaluate("!!document.querySelector('#{selector}')")
        return true if found
        sleep 1
      end
      false
    end

    # Navigate to the next page of search results
    # Tries clicking the pagination "next" button first, falls back to URL manipulation
    def navigate_to_next_page(page_num)
      # Strategy 1: Click the Next/right-arrow pagination button via JS
      clicked = browser.evaluate(<<~JS)
        (function() {
          // Look for pagination next buttons
          var selectors = [
            'button[aria-label="Next"]',
            'button[aria-label="next"]',
            'button[aria-label="Next page"]',
            'a[aria-label="Next"]',
            'a[aria-label="Next page"]',
            '[class*="pagination"] button:last-child',
            '[class*="pagination"] a:last-child',
            '[class*="pager"] [class*="next"]',
            '[class*="Pagination"] [class*="next"]',
            '[class*="Pagination"] [class*="Next"]',
            'button[class*="next"]',
            'a[class*="next"]'
          ];
          for (var i = 0; i < selectors.length; i++) {
            var btn = document.querySelector(selectors[i]);
            if (btn && btn.offsetHeight > 0 && !btn.disabled) {
              btn.click();
              return 'clicked:' + selectors[i];
            }
          }

          // Look for a ">" or "›" or "»" button in pagination
          var pageButtons = document.querySelectorAll('[class*="pagination"] button, [class*="pagination"] a, [class*="pager"] button, [class*="pager"] a');
          for (var i = 0; i < pageButtons.length; i++) {
            var text = (pageButtons[i].innerText || '').trim();
            if ((text === '>' || text === '›' || text === '»' || text === '→') && pageButtons[i].offsetHeight > 0) {
              pageButtons[i].click();
              return 'arrow:' + text;
            }
          }

          // Look for a page number button matching the target page
          for (var i = 0; i < pageButtons.length; i++) {
            var text = (pageButtons[i].innerText || '').trim();
            if (text === '#{page_num}' && pageButtons[i].offsetHeight > 0) {
              pageButtons[i].click();
              return 'page_num:' + text;
            }
          }

          return false;
        })()
      JS

      if clicked
        logger.info "[Sysco] Navigated to page #{page_num} via #{clicked}"
        sleep 2
        return true
      end

      # Strategy 2: URL-based pagination — append/change page param
      current_url = browser.current_url rescue ''
      if current_url.include?('shop.sysco.com')
        if current_url.include?('page=')
          next_url = current_url.gsub(/page=\d+/, "page=#{page_num}")
        elsif current_url.include?('?')
          next_url = "#{current_url}&page=#{page_num}"
        else
          next_url = "#{current_url}?page=#{page_num}"
        end

        logger.info "[Sysco] Navigating to page #{page_num} via URL: #{next_url}"
        navigate_to(next_url)
        sleep 2

        # Check if the page actually changed by verifying new product cards loaded
        new_url = browser.current_url rescue ''
        return new_url.include?("page=#{page_num}") || new_url != current_url
      end

      logger.info "[Sysco] Could not navigate to page #{page_num}"
      false
    rescue StandardError => e
      logger.warn "[Sysco] Error navigating to page #{page_num}: #{e.message}"
      false
    end

    # Extract product data from the search results grid
    def extract_search_products
      # First, run a diagnostic to understand the page structure
      diagnostics = browser.evaluate(<<~JS)
        (function() {
          var d = {};
          d.url = location.href;
          d.title = document.title;

          // Check which product card selectors match
          var selectorTests = {
            'product-card': '[class*="product-card"]',
            'productCard': '[class*="productCard"]',
            'product-tile': '[class*="product-tile"]',
            'productTile': '[class*="productTile"]',
            'grid>div': '[class*="grid"] > div',
            'catalog item': '[class*="catalog"] [class*="item"]',
            'card': '[class*="card"]',
            'result': '[class*="result"]',
            'product': '[class*="product"]'
          };
          d.selectorCounts = {};
          for (var name in selectorTests) {
            d.selectorCounts[name] = document.querySelectorAll(selectorTests[name]).length;
          }

          // Sample the first product-ish element
          var sample = document.querySelector('[class*="product-card"], [class*="productCard"], [class*="product-tile"], [class*="card"][class*="product"]');
          if (sample) {
            d.sampleClass = sample.className;
            d.sampleText = (sample.innerText || '').substring(0, 300);
            d.sampleChildCount = sample.childElementCount;
          }

          // Check for "no results" message
          var bodyText = (document.body.innerText || '').substring(0, 2000);
          d.hasNoResults = !!bodyText.match(/no results|0 results|nothing found/i);
          d.resultCountText = (bodyText.match(/\\d+\\s*results?/i) || [''])[0];

          return d;
        })()
      JS
      logger.info "[Sysco] Page diagnostics: #{diagnostics.to_json}" if diagnostics

      result = browser.evaluate(<<~JS)
        (function() {
          var products = [];
          var matchMethod = 'none';

          // Product cards — each card contains: SKU, brand, name+pack, price
          // Try multiple container selectors since we don't know exact classes
          var cards = document.querySelectorAll('[class*="product-card"], [class*="productCard"], [class*="product-tile"], [class*="productTile"]');
          if (cards.length > 0) matchMethod = 'product-card';

          if (cards.length === 0) {
            // Try card elements that contain product-specific data
            cards = document.querySelectorAll('[class*="card"][class*="product"], [class*="item"][class*="product"]');
            if (cards.length > 0) matchMethod = 'card-product';
          }

          if (cards.length === 0) {
            // Fallback: look for grid items that contain Add to Cart buttons
            cards = document.querySelectorAll('[class*="grid"] > div, [class*="catalog"] [class*="item"]');
            if (cards.length > 0) matchMethod = 'grid-div';
          }

          if (cards.length === 0) {
            // Last resort: find elements containing price patterns
            var allDivs = document.querySelectorAll('div');
            var cardSet = [];
            for (var d = 0; d < allDivs.length; d++) {
              var text = allDivs[d].innerText || '';
              if (text.match(/\\$\\d+\\.\\d{2}\\s*(CS|EA|LB)/i) && text.match(/\\d{5,}/) && allDivs[d].childElementCount > 2) {
                // Check it's a leaf-ish card, not a giant container
                if (text.length < 500) cardSet.push(allDivs[d]);
              }
            }
            cards = cardSet;
            if (cards.length > 0) matchMethod = 'price-pattern';
          }

          for (var i = 0; i < cards.length; i++) {
            try {
              var card = cards[i];
              var text = card.innerText || '';
              var lines = text.split('\\n').map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });

              // Extract SKU (7-digit number)
              var sku = null;
              for (var j = 0; j < lines.length; j++) {
                var skuMatch = lines[j].match(/^(\\d{6,8})$/);
                if (skuMatch) { sku = skuMatch[1]; break; }
              }
              if (!sku) {
                // Try finding SKU anywhere in text
                var anySkuMatch = text.match(/\\b(\\d{7})\\b/);
                if (anySkuMatch) sku = anySkuMatch[1];
              }
              if (!sku) continue;

              // Extract price: "$XX.XX CS" or "$XX.XXX LB"
              var priceMatch = text.match(/\\$(\\d+[,\\d]*\\.\\d{2,3})\\s*(CS|EA|LB|CW)/i);
              var price = priceMatch ? parseFloat(priceMatch[1].replace(',', '')) : null;
              var priceUnit = priceMatch ? priceMatch[2].toUpperCase() : null;

              // Extract brand + name + pack size
              // Brand line is usually "Sysco Classic" or "Tyson Red Label"
              // Name line follows with pack size appended: "Chicken Breast... 4/10 LB"
              var brand = '';
              var nameWithPack = '';
              var packSize = null;

              for (var j = 0; j < lines.length; j++) {
                // Brand is usually right before or after SKU
                if (lines[j].match(/^(Sysco|Tyson|Imperial|Buckhead|Arrezzio|Block|Jade Mountain)/i)) {
                  brand = lines[j];
                }
                // Name+pack is a line with pack size pattern at end
                var packMatch = lines[j].match(/(.+?)\\s+(\\d+\\/\\d+[#\\s]?\\w*|\\d+x\\d+\\s*\\w*|\\d+\\s*(LB|OZ|EA|CS|CT|GAL|#|lb|oz)\\b.*)$/i);
                if (packMatch && !lines[j].match(/^\\$/)) {
                  nameWithPack = packMatch[1];
                  packSize = packMatch[2];
                }
              }

              // Build supplier_name: brand + name
              var supplierName = brand;
              if (nameWithPack) {
                supplierName = (supplierName ? supplierName + ' ' : '') + nameWithPack;
              }
              if (!supplierName || supplierName.length < 3) {
                // Fallback: use all text lines except price/sku/button/UI text
                supplierName = lines.filter(function(l) {
                  return !l.match(/^\\$/) && !l.match(/^\\d{6,}$/) && !l.match(/Add to Cart/i) &&
                    !l.match(/DEAL FOR YOU/i) && !l.match(/Add item to/i) && !l.match(/Create List/i) &&
                    !l.match(/^(CS|EA|LB|CW|CT|OZ|GAL)$/i);
                }).join(' ');
              }

              // If pack size not found, try extracting from name
              if (!packSize) {
                var anyPack = supplierName.match(/(\\d+\\/\\d+[#\\s]?\\w*|\\d+\\s*(LB|OZ|EA|CS|CT|#)\\b)/i);
                if (anyPack) packSize = anyPack[1];
              }

              products.push({
                supplier_sku: sku,
                supplier_name: supplierName.substring(0, 255),
                current_price: price,
                pack_size: packSize || null,
                price_unit: priceUnit || null,
                in_stock: !text.match(/out of stock|unavailable/i),
                supplier_url: 'https://shop.sysco.com/app/product/' + sku
              });
            } catch(e) {
              // Skip cards that fail to parse
            }
          }

          // Return both products and metadata for diagnostics
          return { products: products, matchMethod: matchMethod, cardCount: cards.length };
        })()
      JS

      # Unwrap the result — may be the new format {products:, matchMethod:} or legacy array
      raw_products = if result.is_a?(Hash)
        logger.info "[Sysco] Extraction method: #{result['matchMethod']}, cards found: #{result['cardCount']}, products parsed: #{result['products']&.size || 0}"
        result['products'] || []
      else
        result || []
      end

      # browser.evaluate returns JS objects as string-keyed Ruby hashes — symbolize for consistency
      raw_products.map { |p| p.is_a?(Hash) ? p.symbolize_keys : p }
    rescue StandardError => e
      logger.error "[Sysco] Error extracting search products: #{e.message}"
      []
    end

    # ----------------------------------------------------------------
    # List scraping helpers
    # ----------------------------------------------------------------

    # Extract list names from the sidebar under "My Lists"
    def extract_list_sidebar
      result = browser.evaluate(<<~JS)
        (function() {
          var lists = [];
          var sidebar = document.body;

          // Find all clickable list items in the sidebar
          // "My Lists (N)" section contains user-created lists
          // "Sysco Lists (N)" section contains system lists (skip these)
          var allLinks = sidebar.querySelectorAll('a, [role="button"], [class*="list-item"], [class*="listItem"]');
          var inMyLists = false;
          var inSyscoLists = false;

          // First, try to find the section headers
          var allText = sidebar.querySelectorAll('*');
          for (var i = 0; i < allText.length; i++) {
            var el = allText[i];
            var text = (el.innerText || '').trim();

            // Detect "My Lists" section header
            if (text.match(/^My Lists/i) && el.childElementCount <= 2) {
              inMyLists = true;
              inSyscoLists = false;
              continue;
            }
            // Detect "Sysco Lists" section header — stop collecting
            if (text.match(/^Sysco Lists/i) && el.childElementCount <= 2) {
              inMyLists = false;
              inSyscoLists = true;
              continue;
            }

            // Skip "Create a New List" and section headers
            if (text.match(/Create.*List/i) || text.match(/^My Lists/i) || text.match(/^Sysco Lists/i)) continue;

            // Collect list names when we're in the "My Lists" section
            if (inMyLists && el.offsetHeight > 0 && text.length > 0 && text.length < 100) {
              // Make sure it's a leaf element (not a container)
              if (el.childElementCount === 0 || (el.childElementCount <= 2 && el.tagName !== 'DIV')) {
                // Check it's not already collected
                var alreadyHave = false;
                for (var j = 0; j < lists.length; j++) {
                  if (lists[j].name === text) { alreadyHave = true; break; }
                }
                if (!alreadyHave && text.length > 1 && !text.match(/^\\d+$/) && !text.match(/^My Lists/) && !text.match(/^\\s*$/)) {
                  lists.push({ name: text, remote_id: text.toLowerCase().replace(/[^a-z0-9]+/g, '-') });
                }
              }
            }
          }

          return lists;
        })()
      JS

      # browser.evaluate returns JS objects as string-keyed Ruby hashes — symbolize for consistency
      (result || []).map { |l| l.is_a?(Hash) ? l.symbolize_keys : l }
    rescue StandardError => e
      logger.error "[Sysco] Error extracting sidebar lists: #{e.message}"
      []
    end

    # Click a list name in the sidebar
    def click_sidebar_list(list_name)
      clicked = browser.evaluate(<<~JS)
        (function() {
          var els = document.querySelectorAll('a, span, div, [role="button"], [class*="list"]');
          for (var i = 0; i < els.length; i++) {
            var text = (els[i].innerText || '').trim();
            if (text === #{list_name.to_json} && els[i].offsetHeight > 0) {
              els[i].click();
              return true;
            }
          }
          return false;
        })()
      JS

      unless clicked
        logger.warn "[Sysco] Could not click list '#{list_name}' in sidebar"
      end
    end

    # Wait for the list items table to populate
    def wait_for_list_items(timeout: 10)
      timeout.times do
        has_items = browser.evaluate(<<~JS)
          (function() {
            // Check for table rows or item containers
            var rows = document.querySelectorAll('tr, [class*="list-item"], [class*="listItem"], [class*="item-row"]');
            // At least 1 data row (not just header)
            return rows.length > 1;
          })()
        JS
        return true if has_items

        # Check for "no items" message
        no_items = browser.evaluate(<<~JS)
          (function() {
            var text = document.body.innerText || '';
            return text.match(/no items|there are no items/i) ? true : false;
          })()
        JS
        return false if no_items

        sleep 1
      end
      false
    end

    # Extract items from the list detail table
    def extract_list_items
      items = browser.evaluate(<<~JS)
        (function() {
          var items = [];

          // The list table has columns: #, Item Details, Last Ordered, Order Qty, Price ($), Total ($)
          // Each item row shows:
          //   Name on first line
          //   "SKU | Pack Size | Brand" on second line
          //   Price like "$21.31 CS"

          // Try finding rows in a table
          var rows = document.querySelectorAll('tr');
          // Skip header row(s)
          var dataRows = [];
          for (var i = 0; i < rows.length; i++) {
            var text = (rows[i].innerText || '').trim();
            // Data rows contain a SKU (6-8 digit number) and usually a price
            if (text.match(/\\d{6,8}/) && !text.match(/^#.*Item Details/i)) {
              dataRows.push(rows[i]);
            }
          }

          // If no table rows, try card/div-based layout
          if (dataRows.length === 0) {
            var divs = document.querySelectorAll('[class*="item-row"], [class*="listItem"], [class*="list-row"]');
            for (var i = 0; i < divs.length; i++) {
              var text = (divs[i].innerText || '').trim();
              if (text.match(/\\d{6,8}/)) dataRows.push(divs[i]);
            }
          }

          for (var i = 0; i < dataRows.length; i++) {
            try {
              var row = dataRows[i];
              var text = row.innerText || '';
              var lines = text.split('\\n').map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });

              // Find the detail line: "8877383 | 1/50 LB | IMPERIAL FRESH"
              var sku = null;
              var packSize = null;
              var brand = null;

              for (var j = 0; j < lines.length; j++) {
                var detailMatch = lines[j].match(/(\\d{6,8})\\s*\\|\\s*([^|]+?)\\s*\\|\\s*(.+)/);
                if (detailMatch) {
                  sku = detailMatch[1];
                  packSize = detailMatch[2].trim();
                  brand = detailMatch[3].trim();
                  break;
                }
                // Sometimes just SKU without pipes
                var skuOnly = lines[j].match(/^(\\d{6,8})$/);
                if (skuOnly) sku = skuOnly[1];
              }

              if (!sku) continue;

              // Product name is usually the first meaningful line
              var name = '';
              for (var j = 0; j < lines.length; j++) {
                // Skip position number, checkbox text, SKU lines
                if (lines[j].match(/^\\d{1,3}$/) || lines[j].match(/^\\d{6,8}/) || lines[j].match(/^\\$/)) continue;
                if (lines[j].length > 5 && !lines[j].match(/^(CS|EA|LB|N\\/A|Sold and)/i)) {
                  name = lines[j];
                  break;
                }
              }

              // Extract price: "$21.31 CS" or "$14.050 LB"
              var priceMatch = text.match(/\\$(\\d+[,\\d]*\\.\\d{2,3})\\s*(CS|EA|LB|CW)/i);
              var price = priceMatch ? parseFloat(priceMatch[1].replace(',', '')) : null;
              var priceUnit = priceMatch ? priceMatch[2].toUpperCase() : null;

              // If there's a sale price (strikethrough original), take the lower one
              var allPrices = text.match(/\\$(\\d+[,\\d]*\\.\\d{2,3})/g);
              if (allPrices && allPrices.length > 1) {
                var prices = allPrices.map(function(p) { return parseFloat(p.replace('$', '').replace(',', '')); });
                price = Math.min.apply(null, prices);
              }

              // Extract order quantity from input
              var qtyInputs = row.querySelectorAll('input[type="number"], input[type="text"]');
              var qty = 0;
              for (var q = 0; q < qtyInputs.length; q++) {
                var val = parseFloat(qtyInputs[q].value);
                if (!isNaN(val)) { qty = val; break; }
              }

              items.push({
                sku: sku,
                name: name.substring(0, 255),
                price: price,
                pack_size: packSize || null,
                price_unit: priceUnit || null,
                quantity: qty,
                in_stock: !text.match(/out of stock|unavailable/i),
                position: i + 1
              });
            } catch(e) {
              // Skip rows that fail to parse
            }
          }
          return items;
        })()
      JS

      # browser.evaluate returns JS objects as string-keyed Ruby hashes — symbolize for consistency
      items = (items || []).map { |i| i.is_a?(Hash) ? i.symbolize_keys : i }

      # Scroll down to check for more items not yet in viewport
      if items.is_a?(Array) && items.size > 0
        more_items = scroll_and_extract_remaining_items(items.size)
        items.concat(more_items) if more_items.any?
      end

      items
    rescue StandardError => e
      logger.error "[Sysco] Error extracting list items: #{e.message}"
      []
    end

    # Scroll down to load any additional list items
    def scroll_and_extract_remaining_items(already_have)
      all_new = []
      3.times do |scroll_attempt|
        browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
        sleep 2

        current_count = browser.evaluate(<<~JS)
          (function() {
            var rows = document.querySelectorAll('tr');
            var count = 0;
            for (var i = 0; i < rows.length; i++) {
              if ((rows[i].innerText || '').match(/\\d{6,8}/)) count++;
            }
            return count;
          })()
        JS

        break if current_count <= already_have + all_new.size
      end
      all_new
    end

    # ----------------------------------------------------------------
    # Login helpers
    # ----------------------------------------------------------------

    # Type text into a field using Ferrum's native CDP keyboard events.
    # This sends real browser-level keystrokes with small random delays
    # between characters, which satisfies bot detection that checks for
    # human-like typing patterns. JavaScript-dispatched events all fire
    # in a single frame and get flagged.
    def type_into_field(selectors, text)
      # Find the first visible field matching any selector
      sel = browser.evaluate(<<~JS)
        (function() {
          var selectors = #{selectors.to_json};
          for (var i = 0; i < selectors.length; i++) {
            var el = document.querySelector(selectors[i]);
            if (el && el.offsetHeight > 0) return selectors[i];
          }
          return null;
        })()
      JS
      return false unless sel

      # Click to focus the field
      node = browser.at_css(sel)
      node.click
      sleep 0.2

      # Clear any existing value
      browser.evaluate("document.querySelector('#{sel}').value = ''")
      browser.evaluate("document.querySelector('#{sel}').dispatchEvent(new Event('input', { bubbles: true }))")

      # Type each character with real CDP key events and human-like delays
      text.each_char do |char|
        browser.keyboard.type(char)
        sleep(rand(0.05..0.15)) # 50-150ms between keystrokes
      end

      # Final change event
      browser.evaluate("document.querySelector('#{sel}').dispatchEvent(new Event('change', { bubbles: true }))")
      true
    end

    # Fill the email/username field on the login page
    def fill_login_email
      # Try multiple selectors — Sysco may use various input patterns
      email_selectors = [
        'input[type="email"]',
        'input[name="email"]',
        'input[name="username"]',
        'input[name="loginfmt"]',        # Microsoft/Azure AD
        'input[name="identifier"]',
        'input#signInName',               # Azure AD B2C
        'input#signInName-facade',        # Azure AD B2C facade
        'input#i0116',                    # Microsoft login
        'input[autocomplete="username"]',
        'input[autocomplete="email"]'
      ]

      field = nil
      email_selectors.each do |sel|
        field = browser.at_css(sel) rescue nil
        if field
          logger.info "[Sysco] Found email field: #{sel}"
          break
        end
      end

      return false unless field

      # Use Ferrum's native keyboard typing — sends real Chrome DevTools
      # Protocol key events with natural timing. JavaScript-dispatched events
      # all fire in one frame which bot detection catches.
      type_into_field(email_selectors, credential.username)
    end

    # Fill the password field (appears dynamically after clicking Next)
    def fill_login_password
      password_selectors = [
        'input[type="password"]',
        'input[name="password"]',
        'input[name="passwd"]',           # Microsoft login
        'input#passwordInput',            # Azure AD B2C
        'input#i0118',                    # Microsoft login
        'input[autocomplete="current-password"]'
      ]

      # Wait for password field to appear (loaded via JS after email + Next)
      field = nil
      15.times do |attempt|
        password_selectors.each do |sel|
          candidate = browser.at_css(sel) rescue nil
          if candidate
            visible = browser.evaluate("(function() { var el = document.querySelector('#{sel}'); return el && el.offsetHeight > 0; })()")
            if visible
              field = candidate
              logger.info "[Sysco] Found password field: #{sel} (attempt #{attempt + 1})"
              break
            end
          end
        end
        break if field
        sleep 1
      end

      return false unless field

      # Use Ferrum's native keyboard typing (same as email field)
      type_into_field(password_selectors, credential.password)
    end

    # Click the "Next" button after entering email (advances to password step).
    # Waits for the button to become enabled — enterprise login forms often
    # keep it disabled until their JS validates the email field.
    def click_next_button
      clicked = false
      8.times do |attempt|
        clicked = browser.evaluate(<<~JS)
          (function() {
            // Try common "Next" button patterns
            var selectors = [
              "button#next",
              "button[type='submit']",
              "input[type='submit']",
              "button#idSIButton9"
            ];
            for (var i = 0; i < selectors.length; i++) {
              var btn = document.querySelector(selectors[i]);
              if (btn && btn.offsetHeight > 0 && !btn.disabled) { btn.click(); return true; }
            }

            // Fallback: find button by text content
            var buttons = document.querySelectorAll('button, input[type="submit"], a[role="button"]');
            for (var i = 0; i < buttons.length; i++) {
              var text = (buttons[i].innerText || buttons[i].value || '').trim().toLowerCase();
              if (['next', 'continue', 'sign in', 'log in'].includes(text) && !buttons[i].disabled) {
                buttons[i].click();
                return true;
              }
            }
            return false;
          })()
        JS
        break if clicked
        logger.info "[Sysco] Next button not yet enabled, waiting... (attempt #{attempt + 1}/8)"
        sleep 1
      end

      unless clicked
        logger.warn '[Sysco] Could not find Next button — trying Enter key on email field'
        browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('input[type="email"], input[type="text"]');
            for (var i = 0; i < inputs.length; i++) {
              if (inputs[i].offsetHeight > 0) {
                inputs[i].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
                inputs[i].dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', bubbles: true }));
                inputs[i].dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true }));
                return true;
              }
            }
            return false;
          })()
        JS
      end
    end

    # Click the login/submit button (after password is filled).
    # Waits for the button to become enabled, same as click_next_button.
    def click_login_submit
      clicked = false
      8.times do |attempt|
        clicked = browser.evaluate(<<~JS)
          (function() {
            // Try common submit button patterns
            var selectors = [
              "button[type='submit']",
              "input[type='submit']",
              "button#next",
              "button#idSIButton9",
              "button.btn-primary",
              "button[data-testid='submit']"
            ];
            for (var i = 0; i < selectors.length; i++) {
              var btn = document.querySelector(selectors[i]);
              if (btn && btn.offsetHeight > 0 && !btn.disabled) { btn.click(); return true; }
            }

            // Fallback: find button by text
            var buttons = document.querySelectorAll('button, input[type="submit"], a[role="button"]');
            for (var i = 0; i < buttons.length; i++) {
              var text = (buttons[i].innerText || buttons[i].value || '').trim().toLowerCase();
              if (['sign in', 'log in', 'login', 'submit', 'next', 'continue'].includes(text) && !buttons[i].disabled) {
                buttons[i].click();
                return true;
              }
            }
            return false;
          })()
        JS
        break if clicked
        logger.info "[Sysco] Submit button not yet enabled, waiting... (attempt #{attempt + 1}/8)"
        sleep 1
      end

      unless clicked
        logger.warn '[Sysco] Could not find enabled submit button — trying Enter key on password field'
        browser.evaluate(<<~JS)
          (function() {
            var el = document.querySelector('input[type="password"]');
            if (el) {
              el.dispatchEvent(new KeyboardEvent('keydown',  { key: 'Enter', code: 'Enter', bubbles: true }));
              el.dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', bubbles: true }));
              el.dispatchEvent(new KeyboardEvent('keyup',    { key: 'Enter', code: 'Enter', bubbles: true }));
            }
          })()
        JS
      end
    end

    # ----------------------------------------------------------------
    # MFA handling — optional, detected dynamically after password
    # ----------------------------------------------------------------

    def handle_mfa_if_prompted
      mfa_info = detect_mfa_prompt
      return false unless mfa_info

      logger.info "[Sysco] MFA detected: #{mfa_info[:type]} — #{mfa_info[:message]}"

      # Create a 2FA request for the user to submit their code
      tfa_request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        request_type: 'login',
        status: 'pending',
        prompt_message: mfa_info[:message],
        expires_at: 5.minutes.from_now
      )
      logger.info "[Sysco] Created 2FA request ##{tfa_request.id}, waiting for code..."
      credential.update!(two_fa_enabled: true, status: 'pending')

      # Broadcast via ActionCable so the global 2FA modal appears
      TwoFactorChannel.broadcast_to(
        credential.user,
        {
          type: 'two_fa_required',
          request_id: tfa_request.id,
          session_token: tfa_request.session_token,
          supplier_name: 'Sysco',
          two_fa_type: mfa_info[:type].to_s,
          prompt_message: mfa_info[:message],
          expires_at: tfa_request.expires_at.iso8601
        }
      )

      # Poll for user to enter the code via the web UI
      code = poll_for_2fa_code(tfa_request, timeout: 300)

      unless code
        tfa_request.update!(status: 'expired')
        raise AuthenticationError, 'Verification code was not entered in time'
      end

      # Enter the code
      logger.info '[Sysco] Entering MFA code...'
      enter_mfa_code(code)
      sleep 5

      # Verify success
      if detect_mfa_prompt
        tfa_request.update!(status: 'failed')
        raise AuthenticationError, 'MFA verification failed — still on code entry page'
      end

      # Check for error messages
      page_text = browser.evaluate('document.body?.innerText?.substring(0, 1000)') rescue ''
      if page_text.match?(/wrong.*code|incorrect.*code|invalid.*code/i)
        tfa_request.update!(status: 'failed')
        raise AuthenticationError, 'MFA verification failed: wrong code entered'
      end

      tfa_request.update!(status: 'verified')
      logger.info '[Sysco] MFA code accepted'
      true
    end

    # Detect if the current page is showing an MFA/verification code prompt
    def detect_mfa_prompt
      page_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 3000)')
      rescue StandardError
        ''
      end
      return nil if page_text.blank?

      # Check for common MFA keywords
      mfa_keywords = /verification\s*code|enter\s*(the\s*)?code|multi.?factor|one.?time\s*pass|mfa|two.?factor|security\s*code/i
      return nil unless page_text.match?(mfa_keywords)

      # Confirm there's actually a code input field visible
      has_code_input = browser.evaluate(<<~JS)
        (function() {
          // Look for code input fields (single field or multi-digit)
          var inputs = document.querySelectorAll('input[type="text"], input[type="tel"], input[type="number"]');
          for (var i = 0; i < inputs.length; i++) {
            var el = inputs[i];
            if (el.offsetHeight > 0) {
              var name = (el.name || '').toLowerCase();
              var id = (el.id || '').toLowerCase();
              var placeholder = (el.placeholder || '').toLowerCase();
              var label = (el.getAttribute('aria-label') || '').toLowerCase();
              if (name.match(/code|otp|token|verify|mfa/) ||
                  id.match(/code|otp|token|verify|mfa/) ||
                  placeholder.match(/code|enter|digit|verify/) ||
                  label.match(/code|verify|otp/) ||
                  el.maxLength == 1 || el.maxLength == 6) {
                return true;
              }
            }
          }
          return false;
        })()
      JS
      return nil unless has_code_input

      # Determine MFA type from page content
      mfa_type = if page_text.match?(/text.*message|sms|phone/i)
                   'sms'
                 elsif page_text.match?(/email|inbox/i)
                   'email'
                 else
                   'unknown'
                 end

      # Extract the prompt message
      message = if page_text.match?(/sent.*(?:to|at)\s+(\S+@\S+|\(\d{3}\)\s*\d{3}.?\d{4}|\d{3}.?\d{3}.?\d{4})/i)
                  "Sysco has sent a verification code. #{$&}"
                else
                  "Sysco requires a verification code. Please check your email or phone and enter the code."
                end

      { type: mfa_type, message: message }
    end

    # Enter an MFA code — handles both single-field and multi-digit-field patterns
    def enter_mfa_code(code)
      digits = code.to_s.gsub(/\D/, '').chars

      # Check for multi-field pattern (individual digit inputs like #code1-#code6)
      multi_field = browser.evaluate(<<~JS)
        (function() {
          // Check for numbered code fields
          for (var i = 1; i <= 8; i++) {
            var el = document.querySelector('#code' + i) ||
                     document.querySelector('[name="code' + i + '"]') ||
                     document.querySelector('[data-index="' + (i-1) + '"]');
            if (el && el.offsetHeight > 0) return 'multi';
          }
          // Check for a cluster of maxLength=1 inputs
          var singles = document.querySelectorAll('input[maxlength="1"]');
          if (singles.length >= 4) return 'single_char';
          return 'single_field';
        })()
      JS

      case multi_field
      when 'multi'
        # Individual digit fields (#code1, #code2, etc.)
        digits.each_with_index do |digit, i|
          browser.evaluate(<<~JS)
            (function() {
              var el = document.querySelector('#code#{i + 1}') ||
                       document.querySelector('[name="code#{i + 1}"]') ||
                       document.querySelector('[data-index="#{i}"]');
              if (!el) return;
              el.focus();
              var nativeSetter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
              ).set;
              nativeSetter.call(el, '#{digit}');
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            })()
          JS
          sleep 0.2
        end

      when 'single_char'
        # Multiple maxLength=1 inputs in sequence
        browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('input[maxlength="1"]');
            var digits = #{digits.to_json};
            for (var i = 0; i < Math.min(inputs.length, digits.length); i++) {
              inputs[i].focus();
              var nativeSetter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
              ).set;
              nativeSetter.call(inputs[i], digits[i]);
              inputs[i].dispatchEvent(new Event('input', { bubbles: true }));
              inputs[i].dispatchEvent(new Event('change', { bubbles: true }));
            }
          })()
        JS

      else
        # Single code field — enter the whole code at once
        full_code = digits.join
        browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('input[type="text"], input[type="tel"], input[type="number"]');
            for (var i = 0; i < inputs.length; i++) {
              var el = inputs[i];
              var name = (el.name || '').toLowerCase();
              var id = (el.id || '').toLowerCase();
              var placeholder = (el.placeholder || '').toLowerCase();
              if (el.offsetHeight > 0 && (
                  name.match(/code|otp|token|verify/) ||
                  id.match(/code|otp|token|verify/) ||
                  placeholder.match(/code|enter|digit|verify/) ||
                  el.maxLength == 6 || el.maxLength == 8)) {
                el.focus();
                var nativeSetter = Object.getOwnPropertyDescriptor(
                  window.HTMLInputElement.prototype, 'value'
                ).set;
                nativeSetter.call(el, #{full_code.to_json});
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
              }
            }
            return false;
          })()
        JS
      end

      # Try to submit the code form
      sleep 1
      browser.evaluate(<<~JS)
        (function() {
          var btns = document.querySelectorAll('button, input[type="submit"]');
          for (var i = 0; i < btns.length; i++) {
            var text = (btns[i].innerText || btns[i].value || '').trim().toLowerCase();
            if (['verify', 'submit', 'continue', 'confirm', 'next'].includes(text)) {
              btns[i].click();
              return true;
            }
          }
          // Fallback: click the first visible submit button
          var submit = document.querySelector("button[type='submit']");
          if (submit && submit.offsetHeight > 0) { submit.click(); return true; }
          return false;
        })()
      JS
    end

    # Poll for user-submitted 2FA code (same pattern as US Foods)
    def poll_for_2fa_code(tfa_request, timeout: 300)
      start_time = Time.current
      loop do
        tfa_request.reload
        if %w[submitted verified].include?(tfa_request.status) && tfa_request.code_submitted.present?
          return tfa_request.code_submitted
        end
        return nil if tfa_request.status == 'cancelled'
        return nil if tfa_request.status == 'failed'
        return nil if tfa_request.status == 'expired'
        return nil if Time.current - start_time > timeout

        sleep 2
      end
    end

    # Detect login error messages on the page
    def detect_login_errors
      page_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 2000)')
      rescue StandardError
        ''
      end

      error_patterns = [
        /invalid.*(?:email|password|credentials)/i,
        /account.*(?:locked|disabled|suspended)/i,
        /incorrect.*password/i,
        /username.*not\s*found/i,
        /login.*failed/i,
        /access.*denied/i
      ]

      error_patterns.each do |pattern|
        if page_text.match?(pattern)
          raise AuthenticationError, "Login failed: #{page_text.match(pattern)[0]}"
        end
      end
    end

    # Wait for redirect to shop.sysco.com after successful auth
    def wait_for_post_login_redirect(timeout: 20)
      start_time = Time.current
      loop do
        current = begin
          browser.current_url
        rescue StandardError
          ''
        end
        return true if current.include?('shop.sysco.com')

        if Time.current - start_time > timeout
          logger.warn "[Sysco] Post-login redirect timed out (stuck at: #{current})"
          return false
        end

        sleep 1
      end
    end

    # ----------------------------------------------------------------
    # Stealth browser setup (adapted from US Foods)
    # ----------------------------------------------------------------

    def build_stealth_browser_opts
      ua = if ENV['BROWSER_PATH'].present? || Rails.env.production?
             'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
           else
             'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
           end

      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'

      opts = {
        headless: headless_mode ? 'new' : false,
        # Sysco uses JWT tokens (stored in session_data) for all API operations.
        # Browser is only needed briefly for SSO login to capture tokens.
        # Default incognito is fine since we don't rely on browser cookie persistence.
        timeout: 60,
        process_timeout: 60,
        window_size: [1280, 720],
        browser_options: {
          "no-sandbox": true,
          "disable-gpu": true,
          "disable-dev-shm-usage": true,
          "disable-blink-features": 'AutomationControlled',
          "user-agent": ua,
          "disable-features": 'AutomationControlled,TranslateUI',
          "excludeSwitches": 'enable-automation',
          "no-first-run": true,
          "no-default-browser-check": true,
          "disable-component-update": true,
          "disable-session-crashed-bubble": true,
          "disable-extensions": true,
          "disable-default-apps": true,
          "disable-translate": true,
          "disable-sync": true,
          "disable-background-timer-throttling": true,
          "disable-renderer-backgrounding": true,
          "disable-backgrounding-occluded-windows": true,
          "js-flags": '--max-old-space-size=512',
          "renderer-process-limit": 1,
          "disable-software-rasterizer": true,
          "blink-settings": "imagesEnabled=false"
        }
      }
      opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?
      opts
    end

    # Persistent Chrome profile directory per credential.
    # Survives browser restarts — just like closing and reopening your browser.
    def chrome_profile_dir
      @chrome_profile_dir ||= begin
        dir = Rails.root.join('tmp', 'chrome_profiles', "sysco_#{credential.id}")
        FileUtils.mkdir_p(dir)
        dir.to_s
      end
    end

    def setup_network_interception(browser_instance)
      # Block images, fonts, and trackers to save memory.
      # Try multiple approaches since Ferrum versions vary.

      # Approach 1: CDP Network.setBlockedURLs (most reliable)
      blocked = false
      begin
        browser_instance.page.command('Network.enable')
        browser_instance.page.command('Network.setBlockedURLs', urls: [
          '*.jpg', '*.jpeg', '*.png', '*.gif', '*.webp', '*.ico',
          '*.woff', '*.woff2', '*.ttf', '*.eot',
          '*adobedtm.com*', '*analytics*', '*google-analytics*',
          '*googletagmanager*', '*doubleclick*', '*facebook.com/tr*', '*hotjar*'
        ])
        blocked = true
        logger.info '[Sysco] CDP Network.setBlockedURLs enabled'
      rescue StandardError => e
        logger.debug "[Sysco] CDP page.command failed: #{e.message}"
      end

      # Approach 2: Ferrum network intercept (fallback)
      unless blocked
        begin
          browser_instance.network.intercept
          browser_instance.on(:request) do |request|
            url = request.url
            if url.match?(/\.(jpg|jpeg|png|gif|webp|svg|ico|woff|woff2|ttf|eot)(\?|$)/i) ||
               url.include?('adobedtm.com') || url.include?('analytics') ||
               url.include?('googletagmanager')
              request.abort
            else
              request.continue
            end
          end
          blocked = true
          logger.info '[Sysco] Ferrum network intercept enabled'
        rescue StandardError => e
          logger.warn "[Sysco] Ferrum intercept failed: #{e.message}"
        end
      end

      logger.warn '[Sysco] No network blocking active — images will load' unless blocked
    end

    def inject_stealth_scripts(browser_instance)
      stealth_js = <<~JS
        Object.defineProperty(navigator, 'webdriver', {get: () => false});
        Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
        Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
        if (!window.chrome) window.chrome = {};
        if (!window.chrome.runtime) window.chrome.runtime = {};
      JS
      browser_instance.evaluate_on_new_document(stealth_js)
    rescue StandardError => e
      logger.warn "[Sysco] CDP stealth injection failed: #{e.message}"
    end

    def apply_stealth
      browser.evaluate(<<~JS)
        (function() {
          Object.defineProperty(navigator, 'webdriver', {get: () => false});
          Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
          Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
          if (!window.chrome) window.chrome = {};
          if (!window.chrome.runtime) window.chrome.runtime = {};
          var getParameter = WebGLRenderingContext.prototype.getParameter;
          WebGLRenderingContext.prototype.getParameter = function(parameter) {
            if (parameter === 37445) return 'Intel Inc.';
            if (parameter === 37446) return 'Intel Iris OpenGL Engine';
            return getParameter.call(this, parameter);
          };
        })()
      JS
    rescue StandardError
      nil
    end

    # ----------------------------------------------------------------
    # Session management (SPA — save cookies + localStorage + sessionStorage)
    # ----------------------------------------------------------------

    def save_session
      cookies = browser.cookies.all.transform_values(&:to_h)
      local_storage = begin
        browser.evaluate(<<~JS)
          (function() {
            var data = {};
            for (var i = 0; i < localStorage.length; i++) {
              var key = localStorage.key(i);
              data[key] = localStorage.getItem(key);
            }
            return data;
          })()
        JS
      rescue StandardError
        {}
      end
      session_storage = begin
        browser.evaluate(<<~JS)
          (function() {
            var data = {};
            for (var i = 0; i < sessionStorage.length; i++) {
              var key = sessionStorage.key(i);
              data[key] = sessionStorage.getItem(key);
            }
            return data;
          })()
        JS
      rescue StandardError
        {}
      end

      # Extract API tokens for direct HTTP access (no browser needed after login)
      api_tokens = extract_api_tokens_from_browser

      session_blob = {
        cookies: cookies,
        local_storage: local_storage,
        session_storage: session_storage,
        api_tokens: api_tokens
      }.to_json

      credential.update!(
        session_data: session_blob,
        last_login_at: Time.current,
        status: 'active'
      )

      if api_tokens[:jwt]
        jwt_exp = decode_jwt_exp(api_tokens[:jwt])
        hours_left = jwt_exp ? ((jwt_exp - Time.now.to_i) / 3600.0).round(1) : '?'
        logger.info "[Sysco] API tokens saved — JWT expires in #{hours_left}h, shopAccountId=#{api_tokens[:shop_account_id]}"
      end
      logger.info "[Sysco] Session saved (cookies: #{cookies.size}, localStorage: #{local_storage.size})"
    end

    def restore_session
      # With incognito: false and a persistent Chrome profile (user-data-dir),
      # Chrome automatically loads cookies from the profile on startup — just
      # like a real browser. We don't need to inject cookies via CDP.
      #
      # Navigate to /app/discover and then verify via logged_in? which checks
      # the MSS_STATEFUL JWT role (not just the URL, since /app/discover loads
      # for guests too).

      begin
        browser.goto("#{BASE_URL}/app/discover")
      rescue Ferrum::PendingConnectionsError
        nil
      end
      sleep 3
      apply_stealth

      current_url = browser.current_url rescue ''
      logger.info "[Sysco] After profile-based session restore: #{current_url}"

      # Use logged_in? which checks the JWT role — URL alone is unreliable
      # because /app/discover loads for unauthenticated guests too.
      if logged_in?
        logger.info '[Sysco] Profile cookies valid — authenticated (non-GUEST role)'
        true
      else
        logger.info "[Sysco] Profile session expired or guest — need fresh login (URL: #{current_url})"
        false
      end
    rescue StandardError => e
      logger.warn "[Sysco] Session restore error: #{e.message}"
      false
    end

    # ----------------------------------------------------------------
    # Diagnostics
    # ----------------------------------------------------------------

    def log_page_state(context)
      current_url = begin
        browser.current_url
      rescue StandardError
        'unknown'
      end
      page_title = begin
        browser.evaluate('document.title')
      rescue StandardError
        'unknown'
      end
      body_snippet = begin
        browser.evaluate('document.body?.innerText?.substring(0, 500)')
      rescue StandardError
        'could not read'
      end
      logger.info "[Sysco] #{context} — URL: #{current_url}, Title: #{page_title}"
      logger.debug "[Sysco] #{context} — Body: #{body_snippet}"
    end

    def diagnose_login_failure
      log_page_state('Login failure diagnosis')

      buttons = begin
        browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('button, a, input[type="submit"], [role="button"]');
            var info = [];
            for (var i = 0; i < els.length && i < 20; i++) {
              info.push(els[i].tagName + ':' + (els[i].innerText || els[i].value || '').trim().substring(0, 40));
            }
            return info.join(' | ');
          })()
        JS
      rescue StandardError
        'could not read'
      end
      logger.error "[Sysco] Visible buttons: #{buttons}"

      inputs = begin
        browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('input');
            var info = [];
            for (var i = 0; i < els.length && i < 20; i++) {
              var el = els[i];
              info.push(el.type + '#' + el.id + '.' + el.name + ' visible=' + (el.offsetHeight > 0));
            }
            return info.join(' | ');
          })()
        JS
      rescue StandardError
        'could not read'
      end
      logger.error "[Sysco] Visible inputs: #{inputs}"
    end

    # ----------------------------------------------------------------
    # GraphQL API Methods — Direct HTTP, no browser needed
    # ----------------------------------------------------------------

    def ensure_api_session!
      return if api_session_valid?

      logger.info '[Sysco] API tokens expired or missing — logging in via browser...'
      clear_api_token_cache!
      login
      clear_api_token_cache! # Force reload from DB after login saved new tokens
    end

    def api_session_valid?
      tokens = load_api_tokens
      return false unless tokens[:jwt] && tokens[:syy_authorization]

      exp = decode_jwt_exp(tokens[:jwt])
      return false unless exp

      # Valid if JWT doesn't expire for at least 30 minutes
      if exp > Time.now.to_i + 1800
        true
      else
        logger.info "[Sysco] JWT expires in #{((exp - Time.now.to_i) / 60.0).round}min — needs refresh"
        false
      end
    end

    def load_api_tokens
      return @api_tokens if @api_tokens

      raw = credential.session_data
      return {} unless raw

      parsed = JSON.parse(raw) rescue {}
      api = parsed['api_tokens'] || {}

      @api_tokens = {
        jwt: api['jwt'],
        syy_authorization: api['syy_authorization'],
        shop_account_id: api['shop_account_id'],
        seller_id: api['seller_id'],
        site_id: api['site_id']
      }
    end

    def clear_api_token_cache!
      @api_tokens = nil
    end

    def api_headers
      tokens = load_api_tokens
      {
        'Content-Type' => 'application/json',
        'Accept' => '*/*',
        'authorization' => "Bearer #{tokens[:jwt]}",
        'syy-authorization' => tokens[:syy_authorization],
        'Origin' => 'https://shop.sysco.com',
        'Referer' => 'https://shop.sysco.com/',
        'apollographql-client-name' => 'SYSCO_SHOP_WEB',
        'apollographql-client-version' => '1',
        'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
      }
    end

    def graphql_request(operation_name, query, variables = {})
      require 'net/http'
      require 'uri'

      uri = URI.parse(GRAPHQL_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15
      http.read_timeout = 30

      req = Net::HTTP::Post.new(uri.request_uri)
      api_headers.each { |k, v| req[k] = v }

      req.body = {
        operationName: operation_name,
        variables: variables,
        query: query
      }.to_json

      response = http.request(req)

      if response.code == '200'
        JSON.parse(response.body)
      elsif response.code == '401' || response.code == '403'
        error_msg = begin
          JSON.parse(response.body).dig('errors', 0, 'message')
        rescue StandardError
          response.body[0..200]
        end
        logger.error "[Sysco] GraphQL auth error (#{response.code}): #{error_msg}"
        clear_api_token_cache!
        raise AuthenticationError, "Sysco API auth failed: #{error_msg}"
      else
        body_snippet = response.body.to_s[0..1500]
        logger.error "[Sysco] GraphQL #{operation_name} error (#{response.code}): #{body_snippet}"
        # Try to extract a clean GraphQL error message for the exception
        clean_msg = begin
          parsed = JSON.parse(response.body.to_s)
          Array(parsed['errors']).map { |e| e['message'] }.compact.join('; ').presence || body_snippet[0..300]
        rescue StandardError
          body_snippet[0..300]
        end
        raise ScrapingError, "Sysco API error #{response.code} on #{operation_name}: #{clean_msg}"
      end
    end

    def graphql_search_products(term, start: 0, num: PRODUCTS_PER_PAGE)
      data = graphql_request('SearchProducts', search_products_query, {
        isUseGraphStockStatusEnabled: true,
        isGuest: false,
        params: {
          facets: [],
          isShowRestrictedItems: false,
          start: start,
          num: num,
          sort: { type: 'BEST_MATCH', order: 'DESC' },
          pageName: 'CATALOG',
          q: term
        }
      })

      data.dig('data', 'searchProducts')
    end

    def graphql_get_prices(search_results)
      tokens = load_api_tokens
      product_params = search_results.map do |r|
        {
          productId: r['productId'].to_s,
          sellerId: r['sellerId'] || tokens[:seller_id],
          siteId: r['siteId'] || tokens[:site_id],
          quantity: { case: 0, each: 0 },
          splitCode: 'CASE'
        }
      end

      data = graphql_request('Prices', prices_query, {
        isIncludePriceInfoV2: true,
        products: { params: product_params },
        priceOptions: {}
      })

      # Build a map of productId -> price data
      price_products = data.dig('data', 'getProducts') || []
      price_products.each_with_object({}) do |price_product, map|
        map[price_product['productId'].to_s] = price_product
      end
    rescue StandardError => e
      logger.warn "[Sysco] Pricing API error: #{e.message} — returning empty prices"
      {}
    end

    # Build a clean pack_size string from Sysco's packSize API object.
    # The API returns { pack: "4", size: "3 LB", uom: "LB" } — size often
    # already contains the unit, so naively joining all three duplicates it.
    # Strategy: join pack + size, then strip any trailing duplicate unit.
    def build_pack_size(pack_info)
      raw = [pack_info['pack'], pack_info['size']].compact.join(' ').strip
      return nil if raw.blank?

      # Remove duplicate trailing unit: "4 3 LB LB" → "4 3 LB", "9 32OZ OZ" → "9 32OZ"
      raw = raw.sub(/\b(LB|OZ|CT|EA|GAL|KG|CS|IN|ML|DZ|FL)\s+\1\b/i, '\1')
      # Also handle no-space duplication: "32OZOZ" (unlikely but defensive)
      raw = raw.sub(/(LB|OZ|CT|EA|GAL|KG|CS)(LB|OZ|CT|EA|GAL|KG|CS)\z/i) { $1 }
      raw.strip.presence
    end

    def parse_search_result(result, price_map)
      product_id = result['productId'].to_s
      return nil if product_id.blank?

      info = result['productInfo'] || {}
      brand_name = info.dig('brand', 'name') || ''
      product_name = info['name'] || info['description'] || ''
      pack_size_info = info['packSize'] || {}
      pack_size = build_pack_size(pack_size_info)

      stock_indicator = result.dig('availableStockInfo', 'stockIndicator') || 'S'
      is_orderable = info['isOrderable'] != false && info['isShopOrderable'] != false
      in_stock = stock_indicator != 'O' && !info['isPhasedOut'] && is_orderable

      # Determine split/unit info
      sold_as = info['isSoldAs'] || {}
      split_code = if sold_as['split']
                     'EA'
                   else
                     'CS'
                   end

      # Get pricing from the price map
      price_data = price_map[product_id] || {}
      case_price_info = price_data.dig('priceInfoV2', 'case') || {}
      each_price_info = price_data.dig('priceInfoV2', 'each') || {}

      # Prefer case price, fall back to each
      current_price = case_price_info['netPrice'] || case_price_info['price'] ||
                      each_price_info['netPrice'] || each_price_info['price']

      # If we have a case price, unit is CS; if only each, unit is EA
      if case_price_info['netPrice'] || case_price_info['price']
        price_unit = 'CS'
      elsif each_price_info['netPrice'] || each_price_info['price']
        price_unit = 'EA'
      else
        price_unit = split_code
      end

      unit_price = case_price_info['unitPrice'] || each_price_info['unitPrice']

      # Build category from category info
      category = info.dig('category', 'displayName') || info.dig('category', 'mainName')

      supplier_name = [brand_name, product_name].reject(&:blank?).join(' ')

      {
        supplier_sku: product_id,
        supplier_name: supplier_name,
        current_price: current_price&.to_f,
        pack_size: pack_size,
        price_unit: price_unit,
        in_stock: in_stock,
        supplier_url: "#{BASE_URL}/app/product/#{product_id}",
        category: category,
        scraped_at: Time.current
      }
    end

    def graphql_get_list_items(list_id:, list_type:, seller_id:, site_id:)
      tokens = load_api_tokens
      all_items = []
      page = 1

      loop do
        data = graphql_request('GetListItemsV2', get_list_items_v2_query, {
          sellerId: seller_id || tokens[:seller_id],
          siteId: site_id || tokens[:site_id],
          pageNumber: page,
          pageSize: 60,
          listId: list_id,
          listType: list_type,
          itemStatus: 'ACTIVE',
          filters: {},
          sortBy: 'NAME',
          sortOrder: 'ASC',
          groupBy: nil,
          searchTerm: nil
        })

        items_data = data.dig('data', 'getListItemsV2') || {}
        raw_items = items_data['items'] || []
        meta = items_data['meta'] || {}

        raw_items.each_with_index do |item, idx|
          parsed = parse_list_item(item, position: all_items.size + idx + 1)
          all_items << parsed if parsed
        end

        total_pages = meta['totalPages'] || 1
        break if page >= total_pages
        page += 1
      end

      # Get prices for list items
      if all_items.any?
        product_params = all_items.map do |item|
          {
            productId: item[:sku],
            sellerId: tokens[:seller_id],
            siteId: tokens[:site_id],
            quantity: { case: 0, each: 0 },
            splitCode: 'CASE'
          }
        end

        begin
          price_data = graphql_request('Prices', prices_query, {
            isIncludePriceInfoV2: true,
            products: { params: product_params },
            priceOptions: {}
          })

          price_products = price_data.dig('data', 'getProducts') || []
          price_map = price_products.each_with_object({}) { |price_product, map| map[price_product['productId'].to_s] = price_product }

          all_items.each do |item|
            pp = price_map[item[:sku]]
            next unless pp

            case_info = pp.dig('priceInfoV2', 'case') || {}
            each_info = pp.dig('priceInfoV2', 'each') || {}
            item[:price] = case_info['netPrice'] || case_info['price'] ||
                           each_info['netPrice'] || each_info['price'] || item[:price]
            item[:price] = item[:price]&.to_f
            item[:price_unit] = case_info['price'] ? 'CS' : 'EA' if case_info['price'] || each_info['price']
          end
        rescue StandardError => e
          logger.warn "[Sysco] List pricing error: #{e.message}"
        end
      end

      all_items
    end

    def parse_list_item(item, position: 1)
      product = item['product'] || {}
      product_id = product['productId']&.to_s
      return nil if product_id.blank?

      info = product['productInfo'] || {}
      brand_name = info.dig('brand', 'name') || ''
      product_name = info['name'] || info['description'] || ''
      pack_info = info['packSize'] || {}
      pack_size = build_pack_size(pack_info)

      in_stock = info['isOrderable'] != false && info['isShopOrderable'] != false &&
                 !info['isPhasedOut'] && info['isAvailable'] != false

      name = [brand_name, product_name].reject(&:blank?).join(' ')

      {
        sku: product_id,
        name: name,
        price: nil, # Will be filled by pricing call
        pack_size: pack_size,
        price_unit: 'CS',
        quantity: 0,
        in_stock: in_stock,
        position: item['lineNumber'] || position
      }
    end

    # ----------------------------------------------------------------
    # Cart / Order GraphQL operations
    # ----------------------------------------------------------------

    def graphql_create_order(name:, delivery_date: nil)
      # Sysco expects deliveryDate as epoch milliseconds (not ISO date strings).
      # Pass nil to let Sysco pick the next available delivery date.
      delivery_ms = if delivery_date
                      delivery_date.to_time.to_f * 1000
                    end&.to_i

      data = graphql_request('createOrderMutation', create_order_mutation, {
        order: {
          deliveryInstructions: '',
          poNumber: '',
          deliveryDate: delivery_ms,
          name: name,
          orderSource: 'WEB',
          shippingCondition: 'GROUND',
          invoiceSeparate: false,
          originatedOrderSource: 'WEB',
          lineItems: []
        },
        idempotencyToken: SecureRandom.uuid
      })

      order = data.dig('data', 'createOrderV2')
      unless order
        errors = data.dig('errors')&.map { |e| e['message'] }&.join(', ') || 'unknown error'
        logger.error "[Sysco] createOrderV2 failed: #{errors}"
        logger.error "[Sysco] Full response: #{data.to_json[0..500]}"
        raise ScrapingError, "createOrderV2 failed: #{errors}"
      end
      order
    end

    def graphql_update_order(order_id:, sequence_id:, line_items:)
      data = graphql_request('UpdateOrder', update_order_mutation, {
        order: {
          id: order_id,
          orderSource: 'WEB',
          invoiceSeparate: false,
          sequenceId: sequence_id,
          lineItems: line_items
        },
        isPatching: true
      })

      updated = data.dig('data', 'updateOrderV2')
      raise ScrapingError, 'updateOrderV2 returned nil' unless updated
      updated
    end

    def graphql_delete_order(order_id)
      graphql_request('DeleteOrder', delete_order_mutation, { orderId: order_id })
    end

    # Returns an array of ISO date strings (YYYY-MM-DD) that Sysco currently
    # accepts as delivery dates for this account at the given shipping tier.
    # shipping_condition 0 = GROUND (standard delivery route).
    # Sysco refreshes this list as cutoff times roll over, so we call it
    # right before submit rather than caching.
    def graphql_available_delivery_days(shipping_condition: 0)
      data = graphql_request(
        'GetDeliveryDays',
        'query GetDeliveryDays($sc: Int!) { getDeliveryDays(shippingCondition: $sc) { availableDays } }',
        { sc: shipping_condition }
      )
      (data.dig('data', 'getDeliveryDays', 'availableDays') || []).compact
    rescue StandardError => e
      logger.warn "[Sysco] getDeliveryDays failed: #{e.message}"
      []
    end

    def graphql_submit_order(order_id:, sequence_id:)
      cached = @last_sysco_line_items || []
      if cached.empty?
        raise ScrapingError, 'Cannot submit: no cached line items (add_to_cart must run first)'
      end

      # submitOrderV2 has stricter validation than updateOrderV2:
      #   - lineItems[].lineNumber is required (sequential, 1-indexed)
      #   - lineItems[].commissionBasis must NOT be sent (must be null)
      #   - lineItems[].id must NOT be sent (must be null)
      #   - lineItems[].price + pricingType is re-validated against Sysco's
      #     live pricing engine. updateOrderV2 accepts any price we send,
      #     but submitOrderV2 rejects "pricingType [N] is not compatible
      #     with price [X]" when the item has deal/contract pricing that
      #     differs from the list price. Strip price/pricingType/totalPrice
      #     so Sysco applies fresh live pricing server-side.
      submit_line_items = cached.each_with_index.map do |li, idx|
        tokens = load_api_tokens
        {
          lineNumber: idx + 1,
          qty: li[:qty] || li['qty'],
          soldAs: 'cs',
          productId: (li[:productId] || li['productId']).to_s,
          siteId: tokens[:site_id],
          sellerId: tokens[:seller_id]
        }
      end

      # submitOrderV2 advances the order version, so sequenceId must be the
      # NEXT version (cached_seq + 1), not the current one. Sending the
      # current value yields "failed to update the order since the given
      # order version is obsolete" (code 5022).
      next_sequence_id = sequence_id.to_i + 1

      # deliveryDate is REQUIRED on submit. Send noon UTC of the delivery
      # day: Sysco rejects midnight UTC with "The given delivery date is
      # invalid" (code 1002), likely because midnight UTC falls on the
      # previous day in US timezones. Noon UTC is safely inside the
      # delivery day regardless of timezone interpretation.
      delivery_ms = @last_sysco_delivery_ms
      if delivery_ms
        t = Time.at(delivery_ms / 1000).utc
        noon_utc = Time.utc(t.year, t.month, t.day, 12, 0, 0)
        delivery_ms = (noon_utc.to_f * 1000).to_i
      end

      submit_payload = {
        id: order_id,
        name: @last_sysco_order_name || Time.current.strftime('%b %d %Y %I:%M %p'),
        orderSource: 'WEB',
        originatedOrderSource: 'WEB',
        sequenceId: next_sequence_id,
        shippingCondition: 'GROUND',
        invoiceSeparate: false,
        deliveryInstructions: '',
        poNumber: '',
        deliveryDate: delivery_ms,
        lineItems: submit_line_items
      }
      data = graphql_request('SubmitOrder', submit_order_mutation, {
        order: submit_payload
      })

      submitted = data.dig('data', 'submitOrderV2')
      unless submitted
        errors_arr = data.dig('errors') || []
        # Surface nested serviceResponse errors (Sysco wraps backend validation
        # errors inside extensions.serviceResponse.errors).
        detailed = errors_arr.flat_map do |err|
          outer = err['message']
          svc = err.dig('extensions', 'serviceResponse', 'errors')
          if svc.is_a?(Array)
            svc.map { |s| "#{s['message']} (code=#{s['code']})" }
          else
            [outer]
          end
        end
        msg = detailed.join('; ').presence || 'unknown error'
        logger.error "[Sysco] submitOrderV2 failed: #{msg}"
        logger.error "[Sysco] Full response: #{data.to_json[0..3000]}"
        raise ScrapingError, "submitOrderV2 failed: #{msg}"
      end
      submitted
    end

    def graphql_get_open_orders
      tokens = load_api_tokens

      # Extract sellerAccountId from shop_account_id (e.g., "usbl-019-707689" → "707689")
      seller_account_id = tokens[:shop_account_id]&.split('-')&.last

      data = graphql_request('GetOrderHeadersForAccounts', get_order_headers_query, {
        accounts: [{
          shopAccountId: tokens[:shop_account_id],
          showSurcharge: false,
          surchargePercentage: 0,
          pricingV2Enabled: true,
          timeZone: 'America/Indianapolis',
          ordersCount: 20,
          sellerAccounts: [{
            sellerId: tokens[:seller_id],
            siteId: tokens[:site_id],
            sellerAccountId: seller_account_id
          }]
        }],
        filters: {
          deliveryDateFrom: ((Time.now.to_f - 30 * 86_400) * 1000).to_i,
          orderSources: %w[SAM_ORDER SHOP_ORDER MOBILE_ORDER ESYSCO_ORDER SYSCO_MARKET_ORDER
                           COUNTS_ORDER SMX_ORDER SUS_ORDER UNKNOWN_SOURCE PANTRY_LITE_ORDER OTHER],
          hasHeaderErrors: false,
          filterGroups: 'DELIVERY_DATE|SUBMITTED_DATE,EXCEPTIONS,SHIPPING_TYPE,FILTER_STATUS'
        }
      })

      data.dig('data', 'getOrderHeadersForAccounts', 0, 'orderHeaders') || []
    end

    # ----------------------------------------------------------------
    # Cart / Order GraphQL query definitions
    # ----------------------------------------------------------------

    def create_order_mutation
      <<~GQL
        mutation createOrderMutation($order: OrderInputV2!, $idempotencyToken: String, $container: ContainerInput) {
          createOrderV2(
            order: $order
            idempotencyToken: $idempotencyToken
            container: $container
          ) {
            id
            name
            status
            sequenceId
            totalPrice
            totalLineItems
          }
        }
      GQL
    end

    def update_order_mutation
      <<~GQL
        mutation UpdateOrder($order: OrderInputV2!, $isPatching: Boolean) {
          updateOrderV2(
            order: $order
            isPatching: $isPatching
          ) {
            id
            status
            sequenceId
            totalPrice
            totalLineItems
            lineItems {
              id
              productId
              qty
              soldAs
              netUnitPrice
              price
              pricingType
              totalPrice
            }
          }
        }
      GQL
    end

    def delete_order_mutation
      <<~GQL
        mutation DeleteOrder($orderId: String!) {
          deleteOrderV2(orderId: $orderId) {
            __typename
          }
        }
      GQL
    end

    def get_order_headers_query
      <<~GQL
        query GetOrderHeadersForAccounts($accounts: [AccountFilterInput!]!, $filters: OrderFilterInput) {
          getOrderHeadersForAccounts(accounts: $accounts, filters: $filters) {
            shopAccountId
            orderHeaders {
              id
              name
              status
              totalPrice
              totalLineItems
              deliveryDate
              orderSource
              originatedOrderSource
              createdDate
            }
          }
        }
      GQL
    end

    def submit_order_mutation
      # OrderSubmitResponseV2 is a wrapper type — the fields available on it
      # are not documented and introspection is disabled in prod. Use the
      # universally-valid __typename selector so the mutation validates and
      # executes. After submission we look up the order's status/confirmation
      # via getOrderHeadersForAccounts.
      <<~GQL
        mutation SubmitOrder($order: OrderInputV2!) {
          submitOrderV2(order: $order) {
            __typename
          }
        }
      GQL
    end

    # ----------------------------------------------------------------
    # Token extraction
    # ----------------------------------------------------------------

    def extract_api_tokens_from_browser
      # Extract the JWT from localStorage
      jwt = browser.evaluate(<<~JS)
        (function() {
          var raw = localStorage.getItem('gatewayCredentials');
          if (!raw) return null;
          try { var p = JSON.parse(raw); return p.access_token || p; } catch(e) { return raw; }
        })()
      JS

      # Extract syy-authorization by capturing it from a real GraphQL request
      syy_auth = nil
      begin
        browser.page.command('Network.enable')
        captured = nil
        browser.on('Network.requestWillBeSent') do |params|
          next if captured
          next unless params['request']['url'].include?('gateway-api.shop.sysco.com/graphql')
          captured = params['request']['headers']
        end

        # Trigger a lightweight request to capture headers
        perform_spa_search('test')
        sleep 4

        syy_auth = captured&.[]('syy-authorization')
      rescue StandardError => e
        logger.warn "[Sysco] Could not capture syy-authorization header: #{e.message}"
      end

      # If we couldn't capture via network, try to build it from localStorage
      unless syy_auth
        syy_auth = build_syy_authorization_from_storage
      end

      # Extract account info from the syy-auth blob
      shop_account_id = nil
      seller_id = nil
      site_id = nil
      if syy_auth
        begin
          decoded = JSON.parse(Base64.decode64(syy_auth))
          shop_account_id = decoded.dig('data', 'shopAccountId')
          first_seller = decoded.dig('data', 'sellers')&.values&.first
          if first_seller
            seller_id = decoded.dig('data', 'sellers')&.keys&.first
            site_id = first_seller['siteId']
          end
        rescue StandardError
          nil
        end
      end

      {
        jwt: jwt,
        syy_authorization: syy_auth,
        shop_account_id: shop_account_id,
        seller_id: seller_id,
        site_id: site_id
      }
    end

    def build_syy_authorization_from_storage
      # Try to build syy-authorization from persist:account in localStorage
      account_data = browser.evaluate("localStorage.getItem('persist:account')") rescue nil
      return nil unless account_data

      begin
        parsed = JSON.parse(account_data)
        # The persist:account key contains stringified JSON for each sub-key
        active_account = JSON.parse(parsed['activeAccount'] || '{}') rescue {}
        shop_account_id = active_account['shopAccountId']
        return nil unless shop_account_id

        # Extract seller info
        seller_accounts = active_account['sellerAccounts'] || []
        sellers = {}
        seller_accounts.each do |sa|
          seller_id = sa['sellerId']
          sellers[seller_id] = {
            sellerAccountId: sa['sellerAccountId'],
            siteId: sa['siteId']
          }
        end

        blob = {
          data: {
            shopAccountId: shop_account_id,
            sellers: sellers,
            shopUserType: active_account['shopUserType'] || 'multi_buyer',
            country: 'US'
          },
          _hash: active_account['hash'] || ''
        }

        Base64.strict_encode64(blob.to_json)
      rescue StandardError => e
        logger.warn "[Sysco] Could not build syy-authorization from localStorage: #{e.message}"
        nil
      end
    end

    def decode_jwt_exp(jwt)
      return nil unless jwt.is_a?(String) && jwt.include?('.')
      payload = jwt.split('.')[1]
      return nil unless payload
      decoded = JSON.parse(Base64.decode64(payload))
      decoded['exp']&.to_i
    rescue StandardError
      nil
    end

    # ----------------------------------------------------------------
    # GraphQL Query Constants — captured from Sysco SPA
    # ----------------------------------------------------------------

    def search_products_query
      <<~GQL
        query SearchProducts($params: ProductSearchQuery!, $isUseGraphStockStatusEnabled: Boolean = false, $isGuest: Boolean = false) {
          searchProducts(params: $params) {
            metaInfo {
              originalQuery { q start num }
              totalResults
              correlationId
            }
            results {
              sellerId
              siteId
              productId
              availableStockInfo {
                inventory {
                  stockStatus @include(if: $isUseGraphStockStatusEnabled)
                }
                stockIndicator
                unitsPerCase
              }
              productInfo {
                name
                description
                brand { id name }
                category { mainName displayName }
                packSize { pack size uom }
                isSoldAs { split case }
                split { min max }
                averageWeightPerCase
                stockType
                stockTypeCode
                isCatchWeight
                isSyscoBrand
                isPhasedOut
                isExpandedAssortment
                images
                isOrderable
                isLeavingSoon
                weightUom
                isShopOrderable
                storageFlag
                constraints {
                  quantity { incrementalOrderQuantity minimumOrderQuantity soldAs }
                }
              }
              productListInfo @skip(if: $isGuest) {
                isFavorite
              }
            }
          }
        }
      GQL
    end

    def prices_query
      <<~GQL
        query Prices($products: ProductQuery!, $priceOptions: PriceOptions, $isIncludePriceInfoV2: Boolean = false) {
          getProducts(products: $products, priceOptions: $priceOptions) {
            productId
            sellerId
            priceInfoV2 @include(if: $isIncludePriceInfoV2) {
              case(products: $products, newAttributeGroupDiscounts: true) {
                netPrice
                price
                unitPrice
                grossPrice
              }
              each(products: $products, newAttributeGroupDiscounts: true) {
                netPrice
                price
                unitPrice
                grossPrice
              }
            }
            productInfo {
              averageWeightPerCase
              isCatchWeight
            }
            availableStockInfo {
              splitIndicator
              unitsPerCase
            }
          }
        }
      GQL
    end

    def get_lists_query
      <<~GQL
        query GetLists($listTypes: [ListType]!) {
          getLists(listTypes: $listTypes) {
            shopAccountId
            listId
            sellerId
            siteId
            listType
            name
            modifiedAt
            createdAt
            createdBy
            version
            isShared
          }
        }
      GQL
    end

    def get_list_items_v2_query
      <<~GQL
        query GetListItemsV2($sellerId: String, $siteId: String, $listType: ListType!, $listId: String!, $itemStatus: ItemStatus, $filters: ListItemFiltersInputV2, $pageNumber: Int, $pageSize: Int, $sortBy: String, $sortOrder: String, $groupBy: String, $searchTerm: String) {
          getListItemsV2(
            sellerId: $sellerId
            siteId: $siteId
            listType: $listType
            listId: $listId
            filters: $filters
            pageNumber: $pageNumber
            pageSize: $pageSize
            sortBy: $sortBy
            sortOrder: $sortOrder
            groupBy: $groupBy
            searchTerm: $searchTerm
            itemStatus: $itemStatus
          ) {
            items {
              lineNumber
              product {
                siteId
                sellerId
                productId
                productInfo {
                  name
                  description
                  brand { id name }
                  category { mainName displayName }
                  packSize { pack size uom }
                  isSoldAs { split case }
                  averageWeightPerCase
                  storageFlag
                  stockType
                  isCatchWeight
                  isSyscoBrand
                  isPhasedOut
                  isAvailable
                  images
                  isOrderable
                  isShopOrderable
                  weightUom
                }
              }
            }
            meta {
              filteredProductCount
              pageNumber
              totalPages
              totalProductCount
            }
          }
        }
      GQL
    end
  end
end
