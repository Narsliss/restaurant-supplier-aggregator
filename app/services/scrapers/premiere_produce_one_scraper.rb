module Scrapers
  class PremiereProduceOneScraper < BaseScraper
    BASE_URL = 'https://premierproduceone.pepr.app'.freeze
    LOGIN_URL = "#{BASE_URL}/".freeze
    ORDER_MINIMUM = 0.00
    # Checkout is controlled by supplier.checkout_enabled? (database flag)
    # No hardcoded gate — OrderPlacementService passes dry_run: true when checkout is disabled

    # PPO categories for catalog browsing
    # Categories are browsed via URL pattern with category parameter
    PPO_CATEGORIES = [
      { name: 'Produce', slug: 'produce' },
      { name: 'Fresh Fruits', slug: 'fresh-fruits' },
      { name: 'Fresh Vegetables', slug: 'fresh-vegetables' },
      { name: 'Herbs', slug: 'herbs' },
      { name: 'Organic', slug: 'organic' },
      { name: 'Specialty Items', slug: 'specialty' },
      { name: 'Beverages', slug: 'beverages' },
      { name: 'Dairy', slug: 'dairy' },
      { name: 'Dry Goods', slug: 'dry-goods' }
    ].freeze

    # PPO uses passwordless auth: email → code → logged in.
    # Because the verification page is a React SPA with no URL change and no cookies,
    # we MUST keep the browser alive while waiting for the user's code.
    # This method is designed to run inside a Sidekiq job.

    # ══════════════════════════════════════════════════════════════
    # API-based implementation — uses Pepper GraphQL API
    # Token from AWS Cognito, refreshable without browser.
    # Browser only needed for: initial passwordless login (2FA).
    # ══════════════════════════════════════════════════════════════

    def api_client
      @api_client ||= PremiereProduceOneApi.new(credential)
    end

    # ── Auth ────────────────────────────────────────────────────

    def soft_refresh
      if api_client.restore_session
        credential.mark_active!
        logger.info '[PPO] API soft refresh succeeded (Cognito token refresh)'
        true
      else
        logger.warn '[PPO] API soft refresh failed — passwordless login required'
        false
      end
    rescue StandardError => e
      logger.warn "[PPO] Soft refresh error: #{e.message}"
      false
    end

    # ── Lists ───────────────────────────────────────────────────

    def scrape_lists
      api_client.ensure_session!

      delivery_date = (Date.today + 1).strftime('%Y-%m-%dT04:00:00.000Z')

      # Get order guide items
      og_result = api_client.get_order_guide_items
      og_items = og_result&.dig('getOrderGuideItems') || []

      # Get pricing for ALL products (not just order guide — the order guide
      # info endpoint returns fewer items)
      info_result = api_client.get_product_info_list(delivery_date: delivery_date)
      price_list = info_result&.dig('getVariantPackInfoList') || []
      prices_by_id = {}
      price_list.each { |p| prices_by_id[p['variant_pack_id']] = p }

      # Format order guide
      formatted_items = og_items.map.with_index do |og_item, idx|
        vp = og_item['variant_pack'] || {}
        item = vp['item'] || {}
        pack = vp['pack'] || {}
        price_info = prices_by_id[vp['uuid']]
        price = price_info ? (price_info['price_in_micros'] || 0) / 1_000_000.0 : nil

        pack_size, price_unit = parse_ppo_pack(pack, item, price_info)

        {
          sku: vp['external_item_id'],
          name: item['display_name'],
          price: price,
          pack_size: pack_size,
          quantity: 1,
          in_stock: price_info&.dig('availability_status') != 'OUT_OF_STOCK',
          position: idx,
          price_unit: price_unit,
          piece_price: nil,
          piece_pack_size: nil,
          remote_item_id: vp['uuid']
        }
      end

      result = [{
        name: 'Order Guide',
        remote_id: 'order-guide',
        url: BASE_URL,
        list_type: 'order_guide',
        items: formatted_items
      }]

      logger.info "[PPO] API scraped #{formatted_items.size} order guide items"
      result
    end

    # ── Prices ──────────────────────────────────────────────────

    def scrape_prices(product_skus)
      api_client.ensure_session!

      delivery_date = (Date.today + 1).strftime('%Y-%m-%dT04:00:00.000Z')

      # Get all prices
      info_result = api_client.get_product_info_list(delivery_date: delivery_date)
      price_list = info_result&.dig('getVariantPackInfoList') || []

      # Get catalog for product names (keyed by external_item_id)
      catalog_result = api_client.get_catalog(item_limit: 5000)
      catalog_items = catalog_result&.dig('getSupplierVariantPackGroupItems') || []
      products_by_sku = {}
      variant_to_sku = {}
      catalog_items.each do |ci|
        vp = ci['variant_pack'] || {}
        sku = vp['external_item_id']
        products_by_sku[sku] = vp if sku
        variant_to_sku[vp['uuid']] = sku if vp['uuid']
      end

      # Build price lookup by SKU
      prices_by_sku = {}
      price_list.each do |p|
        sku = variant_to_sku[p['variant_pack_id']]
        prices_by_sku[sku] = (p['price_in_micros'] || 0) / 1_000_000.0 if sku
      end

      product_skus.map do |sku|
        product = products_by_sku[sku]
        item = product&.dig('item') || {}
        sp = SupplierProduct.find_by(supplier: credential.supplier, supplier_sku: sku)

        {
          supplier_sku: sku,
          current_price: prices_by_sku[sku],
          in_stock: true,
          supplier_name: item['display_name'] || sp&.supplier_name || sku
        }
      end
    end

    # ── Catalog ─────────────────────────────────────────────────

    def scrape_catalog(search_terms, max_per_term: 50, &on_batch)
      api_client.ensure_session!

      delivery_date = (Date.today + 1).strftime('%Y-%m-%dT04:00:00.000Z')

      # Get full catalog
      catalog_result = api_client.get_catalog(item_limit: 5000)
      catalog_items = catalog_result&.dig('getSupplierVariantPackGroupItems') || []

      # Get pricing
      info_result = api_client.get_product_info_list(delivery_date: delivery_date)
      price_list = info_result&.dig('getVariantPackInfoList') || []
      prices_by_id = {}
      price_list.each { |p| prices_by_id[p['variant_pack_id']] = p }

      results = []

      catalog_items.each_slice(50) do |batch|
        formatted = batch.filter_map do |ci|
          vp = ci['variant_pack'] || {}
          item = vp['item'] || {}
          pack = vp['pack'] || {}
          sku = vp['external_item_id']
          next unless sku

          price_info = prices_by_id[vp['uuid']]
          price = price_info ? (price_info['price_in_micros'] || 0) / 1_000_000.0 : nil

          pack_size, _price_unit = parse_ppo_pack(pack, item, price_info)

          {
            supplier_sku: sku,
            supplier_name: item['display_name'],
            current_price: price,
            pack_size: pack_size,
            in_stock: price_info&.dig('availability_status') != 'OUT_OF_STOCK',
            category: item['category'] || ci['variant_pack_group_display_name'],
            supplier_url: "#{BASE_URL}/item/#{vp['uuid']}"
          }
        end

        if on_batch && formatted.any?
          on_batch.call(formatted)
        else
          results.concat(formatted)
        end
      end

      return [] if on_batch

      deduped = results.uniq { |r| r[:supplier_sku] }
      logger.info "[PPO] API catalog: #{deduped.size} products"
      deduped
    end

    # ── Cart & Orders ───────────────────────────────────────────

    def add_to_cart(items, delivery_date: nil)
      api_client.ensure_session!

      delivery_date_str = (delivery_date || Date.today + 1).to_s
      delivery_date_str = "#{delivery_date_str}T04:00:00.000Z" unless delivery_date_str.include?('T')

      # Get or create a draft order
      open_orders = api_client.get_open_orders
      draft = (open_orders&.dig('orders') || []).first

      unless draft
        create_result = api_client.create_order(delivery_date: delivery_date_str)
        draft = create_result&.dig('createOrder', 'order')
        raise ScrapingError, 'Failed to create draft order' unless draft
      end

      order_uuid = draft['uuid']

      # Look up variant_pack_ids for SKUs
      catalog_result = api_client.get_catalog(item_limit: 5000)
      catalog_items = catalog_result&.dig('getSupplierVariantPackGroupItems') || []
      sku_to_variant = {}
      sku_to_name = {}
      catalog_items.each do |ci|
        vp = ci['variant_pack'] || {}
        sku = vp['external_item_id']
        if sku
          sku_to_variant[sku] = vp['uuid']
          sku_to_name[sku] = vp.dig('item', 'display_name')
        end
      end

      cart_items = []
      failed_items = []

      items.each do |item|
        variant_id = sku_to_variant[item[:sku]]
        if variant_id
          cart_items << {
            variant_pack_id: variant_id,
            quantity: item[:quantity] || 1,
            item_name: sku_to_name[item[:sku]] || item[:name] || ''
          }
        else
          failed_items << { sku: item[:sku], error: 'Not found in catalog', name: item[:name] }
        end
      end

      if cart_items.any?
        result = api_client.update_cart(order_uuid, cart_items)
        unless result&.dig('updateCart', 'order')
          failed_items.concat(cart_items.map { |i| { sku: i[:item_name], error: 'API rejected' } })
          cart_items = []
        end
      end

      # Set delivery date
      if delivery_date && cart_items.any?
        api_client.update_fulfillment(order_uuid, delivery_date_str)
      end

      if failed_items.any? && cart_items.empty?
        raise ItemUnavailableError.new(
          "#{failed_items.count} item(s) could not be added",
          items: failed_items
        )
      end

      { added: cart_items.count, failed: failed_items }
    end

    # Remove individual items from the draft order by SKU.
    # Sets quantity to 0 for matching items.
    def remove_from_cart(skus)
      api_client.ensure_session!
      skus = Array(skus).map(&:to_s)

      open_orders = api_client.get_open_orders
      order = (open_orders&.dig('orders') || []).first
      raise ScrapingError, 'No draft order — call add_to_cart first' unless order

      items = order['orders_items'] || []
      removed = []
      still_present = []

      remove_items = []
      skus.each do |sku|
        item = items.find { |i| i.dig('variants_pack', 'external_item_id').to_s == sku || i.dig('variants_pack', 'sku').to_s == sku || i['sku'].to_s == sku }
        if item
          uuid = item.dig('variants_pack', 'uuid')
          if uuid
            remove_items << { variant_pack_id: uuid, quantity: 0, item_name: item['restaurant_display_name'] || '' }
            removed << sku
          else
            still_present << sku
          end
        else
          still_present << sku
          logger.warn "[PPO] SKU #{sku} not found in order"
        end
      end

      api_client.update_cart(order['uuid'], remove_items) if remove_items.any?
      logger.info "[PPO] Removed #{removed.size}/#{skus.size} items from order"

      { removed: removed, still_present: still_present }
    end

    def clear_cart
      api_client.ensure_session!

      open_orders = api_client.get_open_orders
      (open_orders&.dig('orders') || []).each do |order|
        items = order['orders_items'] || []
        next if items.empty?

        # Set quantity to 0 for each item to remove it
        remove_items = items.filter_map do |item|
          uuid = item.dig('variants_pack', 'uuid')
          next unless uuid
          { variant_pack_id: uuid, quantity: 0, item_name: item['restaurant_display_name'] || '' }
        end

        api_client.update_cart(order['uuid'], remove_items) if remove_items.any?
      end
      logger.info '[PPO] API cart cleared'
    rescue StandardError => e
      logger.warn "[PPO] API clear_cart failed: #{e.message}"
    end

    def checkout(dry_run: false)
      api_client.ensure_session!

      open_orders = api_client.get_open_orders
      order = (open_orders&.dig('orders') || []).first
      raise ScrapingError, 'No draft order to checkout' unless order

      order_uuid = order['uuid']
      order_items = order['orders_items'] || []
      raise ScrapingError, 'Cart is empty' if order_items.empty?

      # Calculate total from price info
      delivery_date = order['restaurant_desired_delivery_time']
      info = api_client.get_product_info_list(delivery_date: delivery_date)
      prices = {}
      (info&.dig('getVariantPackInfoList') || []).each { |p| prices[p['variant_pack_id']] = p }

      total = order_items.sum do |item|
        vp_uuid = item.dig('variants_pack', 'uuid')
        price_info = prices[vp_uuid]
        (price_info&.dig('price_in_micros') || 0) / 1_000_000.0
      end

      if dry_run
        logger.info "[PPO] API DRY RUN — #{order_items.size} items, total=$#{'%.2f' % total}"
        return {
          confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
          total: total,
          delivery_date: delivery_date,
          dry_run: true,
          cart_items: order_items.map { |i| { name: i['restaurant_display_name'] } },
          checkout_summary: {}
        }
      end

      # LIVE ORDER
      logger.warn "[PPO] API PLACING LIVE ORDER — #{order_items.size} items, total=$#{'%.2f' % total}"
      result = api_client.submit_order(order_uuid)
      submitted = result&.dig('submitOrder', 'order')

      confirmation_number = submitted&.dig('uuid') || "PPO-#{Time.current.strftime('%Y%m%d%H%M%S')}"
      logger.info "[PPO] Order placed: #{confirmation_number}"

      {
        confirmation_number: confirmation_number,
        total: total,
        delivery_date: delivery_date,
        dry_run: false,
        cart_items: order_items.map { |i| { name: i['restaurant_display_name'] } },
        checkout_summary: submitted
      }
    end

    def extract_delivery_address
      # PPO doesn't have a separate delivery address concept
      nil
    end

    public

    # ══════════════════════════════════════════════════════════════
    # Browser-based code below (kept for login and fallback)
    # ══════════════════════════════════════════════════════════════

    # Override with_browser to use a longer timeout for 2FA wait.
    # The base class uses 30s, but we need 7 minutes (5 min code wait + buffer).
    def with_browser
      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'

      browser_opts = {
        headless: headless_mode,
        timeout: 420, # 7 minutes to allow for 5-minute 2FA wait + buffer
        process_timeout: 60, # Allow 60 seconds for browser process to start
        window_size: [1920, 1080]
      }

      if headless_mode
        browser_opts[:browser_options] = {
          "no-sandbox": true,
          "disable-gpu": true,
          "disable-dev-shm-usage": true
        }
      else
        browser_opts[:browser_options] = {
          "no-sandbox": true,
          "start-maximized": true
        }
        browser_opts[:headless] = false
      end

      browser_opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?

      logger.info "[Scraper] Starting browser (headless=#{headless_mode}, timeout=7min)"
      @browser = Ferrum::Browser.new(**browser_opts)
      setup_network_interception(@browser)
      yield(browser)
    ensure
      browser&.quit
    end

    def login
      max_code_attempts = 3

      with_browser do
        navigate_to(BASE_URL)

        if restore_session
          browser.refresh
          # Longer timeout for session restore — React needs time to process restored tokens
          wait_for_react_render(timeout: 15)
          logger.info "[PremiereProduceOne] After session restore, logged_in?=#{logged_in?}, url=#{browser.current_url}"
          return true if logged_in?

          logger.info "[PremiereProduceOne] Session restore didn't produce logged-in state, proceeding to full login"
        end

        perform_login_steps

        # PPO always requires a verification code (passwordless auth).
        # Codes may expire quickly (~2 min), so if the first code fails we
        # click "Resend code" and ask the user for a new one, up to max_code_attempts.
        attempt = 0
        while two_fa_page? && attempt < max_code_attempts
          attempt += 1
          resent = attempt > 1

          if resent
            logger.info "[PremiereProduceOne] Code attempt ##{attempt}: clicking Resend code"
            click_button_by_text('resend code')
            sleep 2
          end

          logger.info "[PremiereProduceOne] Verification code page detected (attempt #{attempt}/#{max_code_attempts}) — waiting for user code"
          code = wait_for_user_code(attempt: attempt, resent: resent)

          if code
            type_code_and_submit(code)
            sleep 5
            wait_for_page_load

            # Handle "Stay signed in" / "Trust this device" prompt BEFORE checking
            # logged_in? — if the prompt is blocking, logged_in? would return false
            # and we'd never reach this method. Safe to call when no prompt exists.
            save_trusted_device

            if logged_in?
              save_session
              credential.mark_active!
              mark_2fa_request_verified!
              logger.info '[PremiereProduceOne] Verification successful — logged in!'
              TwoFactorChannel.broadcast_to(credential.user, { type: 'code_result', success: true })
              return true
            end

            # Still on code page — code was likely expired or invalid
            body_text = begin
              browser.evaluate('document.body?.innerText?.substring(0, 2000)')
            rescue StandardError
              ''
            end
            logger.warn "[PremiereProduceOne] Code attempt #{attempt} failed. Page: #{body_text[0..200]}"

            if body_text.match?(/maximum.*attempts|too many.*attempts|try again.*minutes|rate.?limit/i)
              rate_msg = body_text.scan(/maximum.*?minutes\.?|too many.*?minutes\.?|try again.*?minutes\.?/i).first
              error_msg = rate_msg&.strip || 'Too many login attempts. Please wait and try again.'
              credential.mark_failed!(error_msg)
              raise AuthenticationError, error_msg
            end

            # Notify user the code didn't work, but we can retry
            if attempt < max_code_attempts && two_fa_page?
              mark_2fa_request_failed!
              TwoFactorChannel.broadcast_to(
                credential.user,
                { type: 'code_result', success: false,
                  error: 'Code expired or invalid. A new code is being sent — please enter the new code.', can_retry: true }
              )
            end
          else
            credential.mark_failed!('Verification timed out. No code was entered.')
            raise AuthenticationError, 'Verification timed out'
          end
        end

        # Final check after all attempts
        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          mark_2fa_request_failed!
          error_msg = "Verification failed after #{attempt} attempt(s). Please try again."
          credential.mark_failed!(error_msg)
          TwoFactorChannel.broadcast_to(
            credential.user,
            { type: 'code_result', success: false, error: error_msg, can_retry: false }
          )
          raise AuthenticationError, error_msg
        end
      end
    end

    # PPO uses inline verification — the login method polls the database for codes.
    # We intentionally do NOT implement login_with_code so that TwoFactorChannel
    # falls back to just saving the code to the database (see TwoFactorChannel line 83-87).
    # The background job (running login) polls for the code via wait_for_user_code.

    # Override save_session to also capture localStorage.
    # PPO's Pepper React SPA stores auth tokens in localStorage, not just cookies.
    # Without localStorage, cookie-only restore results in an unauthenticated React state.
    def save_session
      cookies = browser.cookies.all.transform_values(&:to_h)

      # Capture localStorage (contains Pepper auth tokens)
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

      session_payload = {
        cookies: cookies,
        local_storage: local_storage
      }.to_json

      credential.update!(
        session_data: session_payload,
        last_login_at: Time.current,
        status: 'active'
      )

      ls_keys = local_storage.is_a?(Hash) ? local_storage.keys : []
      logger.info "[PremiereProduceOne] Session saved (#{cookies.size} cookies, #{ls_keys.size} localStorage keys: #{ls_keys.first(5).join(', ')})"
    end

    # Override restore_session to also restore localStorage.
    # Must restore localStorage BEFORE refreshing the page so React picks up the tokens.
    # Uses a longer session TTL (24h) since PPO requires 2FA and we want to avoid
    # re-authentication as much as possible.
    def restore_session
      return false unless credential.session_data.present?
      # Delegate TTL check to the model (24h for 2FA suppliers, 6h for password)
      # to avoid inconsistent validity windows across scrapers.
      return false unless credential.session_valid?

      begin
        data = JSON.parse(credential.session_data)

        # Support both old format (flat cookie hash) and new format (with local_storage)
        if data.key?('cookies')
          cookies = data['cookies']
          local_storage = data['local_storage'] || {}
        else
          # Legacy format: entire session_data is cookies
          cookies = data
          local_storage = {}
        end

        # Restore cookies
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
          rescue Ferrum::BrowserError => e
            logger.debug "[PremiereProduceOne] Skipping cookie '#{params[:name]}': #{e.message}"
          end
        end

        # Restore localStorage (Pepper auth tokens)
        if local_storage.is_a?(Hash) && local_storage.any?
          # Serialize data into JS string (Ferrum doesn't support argument passing)
          ls_json = local_storage.to_json
          browser.evaluate(<<~JS)
            (function() {
              var data = #{ls_json};
              for (var key in data) {
                if (data.hasOwnProperty(key)) {
                  try { localStorage.setItem(key, data[key]); } catch(e) {}
                }
              }
            })()
          JS
          logger.info "[PremiereProduceOne] Restored #{local_storage.size} localStorage keys"
        end

        logger.info "[PremiereProduceOne] Session restored (#{cookies.size} cookies, #{local_storage.size} localStorage keys)"
        true
      rescue JSON::ParserError => e
        logger.warn "[PremiereProduceOne] Failed to parse session data: #{e.message}"
        false
      end
    end

    def logged_in?
      # Check for common logged-in UI elements
      if browser.at_css('.user-menu, .account-dropdown, .logged-in, [data-user-logged-in], .my-account, .account-nav').present?
        return true
      end

      # Definitely NOT logged in if we're on the verification code page
      return false if two_fa_page?

      # PPO-specific: check for buttons/links that only appear when logged in.
      # "Log out" is in the footer/menu and won't appear in the first 3000 chars of body text
      # because PPO shows dozens of product listings first.
      has_logout = begin
        browser.evaluate("!!document.querySelector('button') && Array.from(document.querySelectorAll('button')).some(function(b) { return b.innerText.trim().toLowerCase() === 'log out'; })")
      rescue StandardError
        false
      end
      return true if has_logout

      body_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 3000)')
      rescue StandardError
        ''
      end

      # Definitely NOT logged in if we're on the landing page
      if body_text.match?(/become a customer/i) && body_text.match?(/explore catalog/i) && !body_text.match?(/order guide|add to cart|my orders/i)
        return false
      end

      # Standard logged-in indicators
      return true if body_text.match?(/my account|sign out|log ?out|my orders|order guide|dashboard/i)

      # PPO-specific: product catalog indicators (prices, "Add note" buttons, etc.)
      return true if body_text.match?(/add to cart|order guide|your cart|checkout|add note/i)

      # If we're not on the login page or code page and we see product-like content, assume logged in
      has_login_page = body_text.match?(/enter.*code|verification.*code|one.?time|sign in to|log in to/i)
      return false if has_login_page

      # Check for product catalog indicators (prices, product names, etc.)
      has_products = browser.at_css("[class*='product'], [class*='catalog'], [class*='item-card'], [class*='order']").present?
      return true if has_products

      false
    end

    # Lightweight session check: restore cookies → navigate → check if still logged in.
    # Browser-based soft refresh (fallback).
    def browser_soft_refresh
      with_browser do
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          wait_for_react_render(timeout: 10)
          if logged_in?
            save_session
            credential.mark_active!
            logger.info '[PremiereProduceOne] Soft refresh successful - session extended'
            return true
          end
        end
        logger.info '[PremiereProduceOne] Soft refresh failed - session expired'
        false
      end
    rescue StandardError => e
      logger.warn "[PremiereProduceOne] Soft refresh error: #{e.message}"
      false
    end

    # Override base scrape_catalog because PPO requires 2FA for login.
    # The base class calls perform_login_steps which only enters the email —
    # Browser-based catalog (fallback).
    def browser_scrape_catalog(search_terms, max_per_term: 50)
      results = []

      with_browser do
        # Try restoring session first
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          # PPO is a React SPA — longer timeout for session restore to process restored tokens
          wait_for_react_render(timeout: 15)
          logger.info "[PremiereProduceOne] After session restore, logged_in?=#{logged_in?}, url=#{browser.current_url}"
        end

        unless logged_in?
          # Full login with 2FA handling (keeps browser alive for code entry)
          perform_login_steps

          if two_fa_page?
            # Need verification code — run the same flow as login()
            max_code_attempts = 3
            attempt = 0

            while two_fa_page? && attempt < max_code_attempts
              attempt += 1
              resent = attempt > 1

              if resent
                logger.info "[PremiereProduceOne] Import login: resending code (attempt #{attempt})"
                click_button_by_text('resend code')
                sleep 2
              end

              code = wait_for_user_code(attempt: attempt, resent: resent)

              if code
                type_code_and_submit(code)
                sleep 5
                wait_for_page_load

                if logged_in?
                  save_session
                  credential.mark_active!
                  save_trusted_device
                  mark_2fa_request_verified!
                  logger.info '[PremiereProduceOne] Import login: verified!'
                  TwoFactorChannel.broadcast_to(credential.user, { type: 'code_result', success: true })
                  break
                end

                if attempt < max_code_attempts && two_fa_page?
                  mark_2fa_request_failed!
                  TwoFactorChannel.broadcast_to(
                    credential.user,
                    { type: 'code_result', success: false, error: 'Code expired or invalid. A new code is being sent.',
                      can_retry: true }
                  )
                end
              else
                credential.mark_failed!('Verification timed out during import. No code was entered.')
                raise AuthenticationError, 'Verification timed out during catalog import'
              end
            end
          end

          unless logged_in?
            credential.mark_failed!('Could not log in for catalog import')
            raise AuthenticationError, 'Could not log in for catalog import'
          end

          save_session
        end

        # Ensure we're on the catalog page with the search input visible.
        # When logged in, PPO shows the catalog directly. If not, click "Explore catalog".
        ensure_catalog_page_loaded

        # Phase 1: Browse categories for broad coverage
        logger.info "[PremiereProduceOne] Phase 1: Browsing #{PPO_CATEGORIES.size} categories"
        PPO_CATEGORIES.each do |category|
          begin
            products = browse_category(category[:slug], max: max_per_term)
            products.each { |p| p[:category] ||= category[:name] }
            results.concat(products)
            logger.info "[PremiereProduceOne] Category '#{category[:name]}': #{products.size} products (total: #{results.size})"
          rescue StandardError => e
            logger.warn "[PremiereProduceOne] Category browse failed for '#{category[:name]}': #{e.class}: #{e.message}"
          end
          rate_limit_delay
        end

        # Optimization: If categories yielded enough products, limit search phase
        category_target = 300
        search_phase_limit = nil
        if results.size >= category_target
          search_phase_limit = 10
          logger.info "[PremiereProduceOne] Categories yielded #{results.size} products (target: #{category_target}). Limiting search phase to #{search_phase_limit} terms."
        else
          logger.info "[PremiereProduceOne] Categories yielded #{results.size} products (below target #{category_target}). Running full search phase."
        end

        # Phase 2: Search terms for items missed in categories
        terms_to_search = search_phase_limit ? search_terms.first(search_phase_limit) : search_terms
        logger.info "[PremiereProduceOne] Phase 2: Searching with #{terms_to_search.size} terms"
        terms_to_search.each do |term|
          begin
            products = search_supplier_catalog(term, max: max_per_term)
            results.concat(products)
            logger.info "[PremiereProduceOne] Search '#{term}': #{products.size} products"
          rescue ScrapingError => e
            logger.warn "[PremiereProduceOne] Search failed for '#{term}': #{e.message}"
          rescue StandardError => e
            logger.warn "[PremiereProduceOne] Unexpected error searching '#{term}': #{e.class}: #{e.message}"
          end

          rate_limit_delay
        end
      end

      # De-duplicate by SKU
      deduped = results.uniq { |r| r[:supplier_sku] }
      logger.info "[PremiereProduceOne] Total unique products: #{deduped.size} (from #{results.size} raw)"
      deduped
    end

    # Scrape order guide(s) from Premiere Produce One (Pepper platform).
    # PPO is a JS SPA — no URL change when navigating. The "Order Guide"
    # link is in the left sidebar. The dropdown chevron may reveal multiple guides.
    # Categories filter within the guide (All, BAKERY & DESSERT, etc.).
    # Override scrape_lists (not scrape_supplier_lists) because PPO requires
    # Browser-based lists (fallback).
    def browser_scrape_lists
      with_browser do
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          wait_for_react_render(timeout: 15)
        end

        unless logged_in?
          perform_login_steps

          if two_fa_page?
            max_code_attempts = 3
            attempt = 0
            while two_fa_page? && attempt < max_code_attempts
              attempt += 1
              resent = attempt > 1
              if resent
                click_button_by_text('resend code')
                sleep 2
              end
              code = wait_for_user_code(attempt: attempt, resent: resent)
              raise AuthenticationError, 'Verification timed out during list import' unless code

              type_code_and_submit(code)
              sleep 5
              wait_for_page_load
              if logged_in?
                save_session
                credential.mark_active!
                save_trusted_device
                mark_2fa_request_verified!
                TwoFactorChannel.broadcast_to(credential.user, { type: 'code_result', success: true })
                break
              end
              next unless attempt < max_code_attempts && two_fa_page?

              mark_2fa_request_failed!
              TwoFactorChannel.broadcast_to(
                credential.user,
                { type: 'code_result', success: false, error: 'Code expired or invalid.', can_retry: true }
              )

            end
          end

          raise AuthenticationError, 'Could not log in for list import' unless logged_in?

          save_session
        end

        # Navigate to Order Guide via sidebar
        navigate_to_order_guide

        # Check for multiple order guides via dropdown
        guides = discover_order_guides

        if guides.empty?
          # Single guide — extract products from current page
          products = extract_order_guide_products_ppo
          return [{
            name: 'Order Guide',
            remote_id: 'order-guide',
            url: BASE_URL,
            list_type: 'order_guide',
            items: products
          }]
        end

        # Multiple guides — scrape each
        result_lists = []
        guides.each do |guide|
          logger.info "[PremiereProduceOne] Scraping guide '#{guide[:name]}'"
          select_order_guide(guide[:name])
          sleep 3
          wait_for_react_render(timeout: 10)

          products = extract_order_guide_products_ppo
          logger.info "[PremiereProduceOne] Guide '#{guide[:name]}': #{products.size} products"

          result_lists << {
            name: guide[:name],
            remote_id: guide[:remote_id],
            url: BASE_URL,
            list_type: 'order_guide',
            items: products
          }

          rate_limit_delay
        end

        result_lists
      end
    end

    def browser_scrape_prices(product_skus)
      results = []

      with_browser do
        # Restore session inline — do NOT call login() which has its own
        # with_browser block and would create a nested browser (killing ours).
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          wait_for_react_render(timeout: 15)
        end
        unless logged_in?
          # PPO is 2FA-only — can't auto-login without user interaction
          raise SessionExpiredError, 'Session expired and cannot auto-login. Please re-authenticate with Premiere Produce One.'
        end
        save_session

        product_skus.each do |sku|
          begin
            result = scrape_product(sku)
            results << result if result
          rescue ScrapingError => e
            logger.warn "[PremiereProduceOne] Failed to scrape SKU #{sku}: #{e.message}"
          end

          rate_limit_delay
        end
      end

      results
    end

    def browser_add_to_cart(items, delivery_date: nil)
      @target_delivery_date = delivery_date
      ensure_order_browser!

      logger.info "[PremiereProduceOne] Logged in, starting add-to-cart for #{items.size} items"
      logger.info "[PremiereProduceOne] Target delivery date: #{@target_delivery_date || 'default'}"

      added_items = []
      failed_items = []

      items.each do |item|
        begin
          add_single_item_to_cart(item)
          added_items << item
          logger.info "[PremiereProduceOne] Added SKU #{item[:sku]} (qty: #{item[:quantity]})"
        rescue StandardError => e
          logger.warn "[PremiereProduceOne] Failed to add SKU #{item[:sku]}: #{e.message}"
          failed_items << { sku: item[:sku], error: e.message, name: item[:name] }
        end

        rate_limit_delay
      end

      if failed_items.any?
        if added_items.empty?
          # ALL items failed — nothing in the cart, can't proceed.
          # Close browser before raising to prevent leak.
          close_order_browser!
          raise ItemUnavailableError.new(
            "#{failed_items.count} item(s) could not be added",
            items: failed_items
          )
        else
          # Some items failed but others succeeded — log warning and continue
          logger.warn "[PremiereProduceOne] #{failed_items.count} item(s) skipped (unavailable): " \
                      "#{failed_items.map { |i| i[:sku] }.join(', ')}"
        end
      end

      # IMPORTANT: Wait for PPO's API to finalize all cart additions before checkout.
      # The last item added has no "next item search" buffer — without this pause,
      # navigating to /cart can reload the page before PPO's backend confirms the add,
      # causing the last item to silently disappear from the cart.
      logger.info "[PremiereProduceOne] All items processed. Waiting for cart to settle..."
      sleep 3

      # Verify cart total reflects expected item count by checking the View Order button
      cart_check = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('button, [role="button"]');
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
            if (aria.includes('view order')) {
              return { found: true, text: (btn.textContent || '').trim() };
            }
          }
          return { found: false };
        })()
      JS
      logger.info "[PremiereProduceOne] Cart button after add-to-cart: #{cart_check.inspect}"

      { added: added_items.count, failed: failed_items }
    end

    # Parse PPO pack data into [pack_size, price_unit].
    #
    # PPO's API returns pack.unit in two formats:
    #   Detailed: "Case - 2-2#", "Each - 1-1 G", "Case - 12-6 OZ"
    #   Bare:     "CASE", "EACH", "BAG", "BOX", "UNIT"
    #
    # For detailed formats, pack_size is already parseable. For bare formats,
    # we enrich with unit_count from the pricing API or item description.
    # price_unit is always just the container type (Case, Each, etc.).
    def parse_ppo_pack(pack, item = {}, price_info = nil)
      raw_unit = pack['unit'].to_s.strip
      unit_count = pack['unit_count'] || price_info&.dig('unit_count')
      description = item['description'].to_s.strip

      # Log available enrichment data for bare pack units so we can improve parsing
      if !raw_unit.include?('-') && raw_unit.upcase.in?(%w[CASE EACH BAG BOX UNIT])
        extras = []
        extras << "unit_count=#{unit_count}" if unit_count.present?
        extras << "description=#{description.first(60)}" if description.present?
        extras << "pack_keys=#{pack.keys.join(',')}" if extras.empty?
        logger.info "[PPO] Bare pack '#{raw_unit}' for '#{item['display_name'].to_s.first(40)}': #{extras.join(', ')}" if extras.any?
      end

      if raw_unit.include?('-')
        # Detailed format: "Case - 2-2#" → pack_size keeps the detail part
        container, detail = raw_unit.split(/\s*-\s*/, 2)
        price_unit = container.strip
        pack_size = raw_unit
      else
        # Bare format: "CASE", "EACH", etc.
        price_unit = raw_unit.presence

        # Extract "Pack Size: 1-3#" or "Pack Size: 12-6 OZ" from description
        # Format: "Brand: ... | Pack Size: <size> | ..."
        pack_size_match = description.match(/Pack Size:\s*([^|]+)/i)
        if pack_size_match
          extracted = pack_size_match[1].strip
          pack_size = "#{raw_unit} - #{extracted}"
        else
          pack_size = raw_unit
        end
      end

      [pack_size, price_unit]
    end

    private

    def add_single_item_to_cart(item)
      # PPO Pepper (pepr.app) Order Guide UI flow:
      # 1. Search for SKU → order guide filters to matching item(s)
      # 2. Click the product ROW → detail modal opens showing "Case • SKU", price, and orange + button
      # 3. Click orange + button in modal to add to cart
      # 4. For qty > 1, click "Increase quantity" button additional times in the modal
      # 5. Close modal, repeat for next item
      #
      # CRITICAL: The + button is ONLY inside the modal — never on the order guide list page.
      # NEVER click any "Increase quantity" button on the main page — those belong to unknown products.

      search_input = browser.at_css("input[placeholder='Search']")
      unless search_input
        ensure_catalog_page_loaded
        search_input = browser.at_css("input[placeholder='Search']")
      end
      raise ScrapingError, 'Search input not found' unless search_input

      # Clear previous search first, then search for the new SKU.
      # Without clearing, React may not re-filter when overwriting the input value.
      begin
        search_input.focus
      rescue Ferrum::BrowserError, Ferrum::NodeNotFoundError => e
        # "Element is not focusable" means React hasn't fully hydrated.
        # Reload the page and retry once — this recovers for all remaining items too.
        logger.warn "[PremiereProduceOne] Search input not focusable (#{e.message}), reloading page and retrying..."
        navigate_to(BASE_URL)
        wait_for_react_render(timeout: 15)
        ensure_catalog_page_loaded
        search_input = browser.at_css("input[placeholder='Search']")
        raise ScrapingError, 'Search input not found after reload' unless search_input
        search_input.focus
      end
      set_react_input_value(search_input, '')
      sleep 1 # Let React process the cleared input and show all items
      set_react_input_value(search_input, item[:sku].to_s)
      sleep 4 # Wait for React to filter/search results

      # Log page state after search for debugging
      page_text = browser.evaluate("document.body ? document.body.innerText.substring(0, 600) : ''") || ''
      logger.info "[PremiereProduceOne] After search for SKU '#{item[:sku]}' (name: #{item[:name]}): #{page_text.first(250).inspect}"

      # Step 2: Click the product row to open the detail modal
      modal_opened = open_product_modal_ppo(item[:sku], item[:name])
      raise ScrapingError, "Could not open product modal for SKU #{item[:sku]}" unless modal_opened

      # Step 3: Click the + button in the modal
      quantity_to_add = [item[:quantity].to_i, 1].max

      # First click: the orange + (add) button
      add_clicked = click_modal_add_button_ppo(item[:sku])
      raise ScrapingError, "Could not click add button in modal for SKU #{item[:sku]}" unless add_clicked
      logger.info "[PremiereProduceOne] Clicked + for SKU #{item[:sku]} (1/#{quantity_to_add})"

      # CRITICAL: Wait for React to process the add-to-cart action.
      # Without this pause, closing the modal immediately can cancel the add.
      # Items with no fulfillment history (never ordered) take longer to register.
      sleep 2.5

      # Diagnostic: verify the + click registered (informational only — do NOT retry
      # the click here, as the CDP mouse.click is reliable and a retry would double the qty).
      add_verified = browser.evaluate(<<~JS)
        (function() {
          var modalContainers = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
          if (modalContainers.length === 0) return { verified: false, reason: 'no modal' };
          var modal = modalContainers[modalContainers.length - 1];
          var text = (modal.textContent || '').trim();
          var buttons = modal.querySelectorAll('button, [role="button"]');
          var hasDecrease = false;
          var hasIncrease = false;
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
            if (aria.includes('decrease')) hasDecrease = true;
            if (aria.includes('increase')) hasIncrease = true;
          }
          return {
            verified: hasDecrease,
            has_decrease: hasDecrease,
            has_increase: hasIncrease,
            modal_text_preview: text.substring(0, 200)
          };
        })()
      JS

      if add_verified&.dig('verified')
        logger.info "[PremiereProduceOne] Add verified for SKU #{item[:sku]}: decrease button present"
      else
        # Log but do NOT retry — retrying causes double-add because the CDP click
        # already succeeded; React just hasn't rendered the decrease button yet.
        logger.warn "[PremiereProduceOne] Add not visually verified for SKU #{item[:sku]} (React may still be rendering): #{add_verified.inspect}"
      end

      # Additional clicks for qty > 1: after first add, the modal shows decrease/increase buttons
      if quantity_to_add > 1
        sleep 0.5 # Wait for UI to update after first add
        (quantity_to_add - 1).times do |i|
          # Find the "Increase quantity" button coordinates, then use CDP mouse click
          increase_result = browser.evaluate(<<~JS)
            (function() {
              var modalContainers = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
              var searchIn = modalContainers.length > 0 ? modalContainers[modalContainers.length - 1] : document;

              var buttons = searchIn.querySelectorAll('button, [role="button"]');
              for (var btn of buttons) {
                if (btn.offsetParent === null) continue;
                var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                if (aria.includes('increase quantity')) {
                  var rect = btn.getBoundingClientRect();
                  return { found: true, aria: aria,
                           x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
                }
              }

              // Fallback: look near the SKU text
              var targetSku = '#{item[:sku]}';
              var allButtons = document.querySelectorAll('button, [role="button"]');
              for (var btn of allButtons) {
                if (btn.offsetParent === null) continue;
                var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                if (aria.includes('increase quantity')) {
                  var parent = btn.parentElement;
                  for (var j = 0; j < 15 && parent; j++) {
                    if ((parent.textContent || '').includes(targetSku)) {
                      var rect = btn.getBoundingClientRect();
                      return { found: true, aria: aria, method: 'sku-match',
                               x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
                    }
                    parent = parent.parentElement;
                  }
                }
              }

              return { found: false, reason: 'No increase button found in modal' };
            })()
          JS

          if increase_result && increase_result['found']
            browser.mouse.click(x: increase_result['x'].to_f, y: increase_result['y'].to_f)
          else
            logger.warn "[PremiereProduceOne] Could only add #{i + 1} of #{quantity_to_add} for SKU #{item[:sku]}: " \
                        "#{increase_result&.dig('reason') || 'unknown'}"
            break
          end

          logger.info "[PremiereProduceOne] Clicked + for SKU #{item[:sku]} (#{i + 2}/#{quantity_to_add})" if i == quantity_to_add - 2
          sleep 0.3
        end
      end

      # Wait for the last qty click to register before closing modal
      sleep 1

      # Step 5: Close the modal
      close_product_modal_ppo

      logger.info "[PremiereProduceOne] Added SKU #{item[:sku]} qty #{quantity_to_add} to cart"
      sleep 1 # Pause before next item (or before checkout for last item)
    end

    # Open the product detail modal by clicking the product row in the order guide.
    # After SKU search, the order guide shows matching items as clickable rows.
    # Clicking a row opens a modal with "Case • SKU", price, and orange + button.
    #
    # KEY LESSONS from debugging:
    # 1. Product names in DB may be longer than Pepper (e.g., "CALIFORNIA JUMBO CARROTS GRIMMWAY FARMS"
    #    vs just "CALIFORNIA JUMBO CARROTS" on screen). Must match bi-directionally.
    # 2. Prefer the SMALLEST matching element — large containers include product name + navigation text.
    # 3. Skip navigation items: "Order Guide", "Catalog", "Cart", etc.
    # 4. React Native Web's Pressable uses pointer events — el.click() does NOTHING.
    #    Must use Ferrum's browser.mouse.click(x:, y:) which sends real CDP mouse events.
    def open_product_modal_ppo(sku, product_name = nil)
      5.times do |attempt|
        # Find the best element to click via JS, return its coordinates
        result = browser.evaluate(<<~JS)
          (function() {
            var targetSku = '#{sku}';
            var productName = #{product_name ? "'#{product_name.gsub("'", "\\\\'")}'" : 'null'};
            var navSkipWords = ['order guide', 'catalog', 'cart', 'sign in', 'sign up', 'log out',
                                'menu', 'settings', 'account', 'no results', 'search'];

            // First: check if modal is already open with our SKU
            // IMPORTANT: Only check inside modal elements ([role="dialog"], [aria-modal="true"]),
            // NOT the full page body — the order guide listing also shows "Case • SKU" text.
            var skuPattern = new RegExp('(?:Case|Each|Piece|Pack|Bag|Box|Unit)\\\\s*[•·]\\\\s*' + targetSku);
            var modals = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
            for (var modal of modals) {
              if (modal.offsetParent === null) continue;
              var modalText = (modal.textContent || '').trim();
              if (skuPattern.test(modalText)) {
                return { already_open: true };
              }
            }

            function isNavText(text) {
              var lower = text.toLowerCase();
              for (var w of navSkipWords) {
                if (lower === w || (lower.length < 30 && lower.includes(w))) return true;
              }
              return false;
            }

            // Strategy 1: Find the BEST element matching the product name
            // Scoring: exact match > full containment > significant word overlap
            if (productName) {
              var nameUpper = productName.toUpperCase();
              var nameWords = nameUpper.split(/\\s+/).filter(function(w) { return w.length > 2; });

              var allElements = document.querySelectorAll('div, span, p, li, a');
              var nameMatches = [];

              for (var el of allElements) {
                if (el.offsetParent === null) continue;
                var text = (el.textContent || '').trim();
                var textUpper = text.toUpperCase();
                if (text.length < 5 || text.length > 200) continue;
                if (isNavText(text)) continue;

                // Score the match quality (higher = better)
                var score = 0;
                var textWords = textUpper.split(/\\s+/).filter(function(w) { return w.length > 2; });

                if (textUpper === nameUpper) {
                  score = 100; // Exact match
                } else if (textUpper.includes(nameUpper)) {
                  score = 80; // Element contains full product name
                } else if (nameUpper.includes(textUpper) && textWords.length >= 2) {
                  // Product name contains element text — require at least 2 significant words
                  // to prevent single-word matches like "ZUCCHINI" matching any zucchini
                  score = 60;
                } else {
                  // Word overlap: count how many product name words appear in element text
                  var matchedWords = 0;
                  for (var w of nameWords) {
                    if (textUpper.includes(w)) matchedWords++;
                  }
                  var overlapRatio = nameWords.length > 0 ? matchedWords / nameWords.length : 0;
                  // Require >50% word overlap to consider it a match
                  if (overlapRatio > 0.5 && matchedWords >= 2) {
                    score = Math.round(overlapRatio * 50);
                  }
                }

                if (score > 0) {
                  var rect = el.getBoundingClientRect();
                  if (rect.width > 30 && rect.height > 10) {
                    nameMatches.push({
                      text: text,
                      textLen: text.length,
                      score: score,
                      x: rect.left + rect.width / 2,
                      y: rect.top + rect.height / 2,
                      width: rect.width,
                      height: rect.height
                    });
                  }
                }
              }

              // Sort by score (highest first), then by text length (shortest first for tiebreak)
              nameMatches.sort(function(a, b) {
                if (b.score !== a.score) return b.score - a.score;
                return a.textLen - b.textLen;
              });

              if (nameMatches.length > 0) {
                var best = nameMatches[0];
                // Scroll the element into view first
                var scrollEl = document.elementFromPoint(best.x, best.y);
                if (scrollEl) scrollEl.scrollIntoView({ behavior: 'instant', block: 'center' });
                // Recalculate position after scroll
                var allEls2 = document.querySelectorAll('div, span, p, li, a');
                for (var el2 of allEls2) {
                  if (el2.offsetParent === null) continue;
                  var t2 = (el2.textContent || '').trim();
                  if (t2 === best.text.trim()) {
                    var r2 = el2.getBoundingClientRect();
                    best.x = r2.left + r2.width / 2;
                    best.y = r2.top + r2.height / 2;
                    break;
                  }
                }
                return {
                  found: true, strategy: 'product-name',
                  text: best.text.substring(0, 80), matchLen: best.textLen,
                  x: best.x, y: best.y,
                  matches_found: nameMatches.length
                };
              }
            }

            // Strategy 2: Find clickable elements with cursor:pointer
            var candidates = [];
            var allDivs = document.querySelectorAll('div, li, span');
            for (var div of allDivs) {
              if (div.offsetParent === null) continue;
              var style = window.getComputedStyle(div);
              if (style.cursor !== 'pointer') continue;

              var text = (div.textContent || '').trim();
              if (text.length < 5 || text.length > 100) continue;
              if (isNavText(text)) continue;

              var rect = div.getBoundingClientRect();
              if (rect.width > 100 && rect.height > 20 && rect.height < 200 && rect.top > 50) {
                candidates.push({
                  text: text.substring(0, 80),
                  textLen: text.length,
                  x: rect.left + rect.width / 2,
                  y: rect.top + rect.height / 2
                });
              }
            }

            candidates.sort(function(a, b) { return a.textLen - b.textLen; });

            if (candidates.length > 0) {
              var c = candidates[0];
              return {
                found: true, strategy: 'cursor-pointer',
                text: c.text, x: c.x, y: c.y,
                candidates_count: candidates.length
              };
            }

            return {
              found: false,
              reason: 'No product element found',
              body_preview: body.substring(0, 300)
            };
          })()
        JS

        logger.info "[PremiereProduceOne] open_product_modal attempt #{attempt + 1}: #{result.inspect}"

        return true if result&.dig('already_open')

        if result&.dig('found')
          x = result['x'].to_f
          y = result['y'].to_f

          # Use Ferrum's real mouse click (CDP Input.dispatchMouseEvent)
          # This triggers React Native Web's Pressable event handlers
          logger.info "[PremiereProduceOne] Clicking at (#{x.round(1)}, #{y.round(1)}) via CDP mouse — #{result['strategy']}: #{result['text']}"
          browser.mouse.click(x: x, y: y)

          sleep 2 # Wait for modal animation

          # Check if modal opened with our SKU
          modal_check = browser.evaluate(<<~JS)
            (function() {
              var targetSku = '#{sku}';
              var body = document.body ? document.body.innerText : '';
              var skuPattern = new RegExp('(?:Case|Each|Piece|Pack|Bag|Box|Unit)\\\\s*[•·]\\\\s*' + targetSku);
              var hasModal = document.querySelectorAll('[role="dialog"], [aria-modal="true"]').length > 0;
              // Also search for just the raw SKU number near a bullet/dot
              var rawSkuPattern = new RegExp('[•·]\\\\s*' + targetSku + '(?:\\\\D|$)');
              // Look for dialog content — use word-boundary match to prevent substring false positives
              // e.g., SKU "567" must not match "5678" in the dialog
              var dialogs = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
              var dialogText = '';
              for (var d of dialogs) { dialogText += (d.textContent || '') + ' '; }
              var skuBoundaryPattern = new RegExp('(?:^|\\\\D)' + targetSku + '(?:\\\\D|$)');
              return {
                has_sku_text: skuPattern.test(body),
                has_raw_sku: rawSkuPattern.test(body),
                has_sku_in_dialog: skuBoundaryPattern.test(dialogText),
                has_modal_role: hasModal,
                dialog_text: dialogText.substring(0, 300),
                body_preview: body.substring(0, 600)
              };
            })()
          JS

          logger.info "[PremiereProduceOne] Modal check: sku_text=#{modal_check&.dig('has_sku_text')}, " \
                      "raw_sku=#{modal_check&.dig('has_raw_sku')}, " \
                      "sku_in_dialog=#{modal_check&.dig('has_sku_in_dialog')}, " \
                      "modal_role=#{modal_check&.dig('has_modal_role')}, " \
                      "dialog=#{modal_check&.dig('dialog_text')&.first(150)&.inspect}"

          # Accept the modal if SKU text is found in any form
          sku_found = modal_check&.dig('has_sku_text') || modal_check&.dig('has_raw_sku') || modal_check&.dig('has_sku_in_dialog')

          if sku_found
            logger.info "[PremiereProduceOne] Modal opened with SKU #{sku}"
            return true
          end

          # Modal didn't open or wrong product — close anything and retry
          close_product_modal_ppo
          sleep 1
        else
          sleep 1
        end
      end

      logger.error "[PremiereProduceOne] Failed to open product modal for SKU #{sku} after 5 attempts"
      false
    end

    # Click the orange + (add to cart) button inside the product detail modal.
    # The modal shows: product name, "Case • SKU", price, and an orange + button.
    # After clicking, the + button transforms into decrease/qty/increase controls.
    # Uses Ferrum's CDP mouse click since React Native Web Pressable ignores el.click().
    def click_modal_add_button_ppo(sku)
      3.times do |attempt|
        # Find the + button coordinates via JS
        result = browser.evaluate(<<~JS)
          (function() {
            var targetSku = '#{sku}';

            // Scope to modal container if one exists
            var modalContainers = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
            var searchIn = modalContainers.length > 0 ? modalContainers[modalContainers.length - 1] : document;

            // Look for "Increase quantity" or "Add" button
            var buttons = searchIn.querySelectorAll('button, [role="button"]');
            for (var btn of buttons) {
              if (btn.offsetParent === null) continue;
              var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
              var text = (btn.textContent || '').trim();
              if (aria.includes('increase quantity') || aria.includes('add to cart') ||
                  aria === 'add' || text === '+') {
                var rect = btn.getBoundingClientRect();
                return { found: true, method: 'aria-match', aria: aria, text: text,
                         x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
              }
            }

            // Try any button with SVG (skip known non-add buttons)
            for (var btn of buttons) {
              if (btn.offsetParent === null) continue;
              var svg = btn.querySelector('svg');
              if (!svg) continue;
              var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
              if (aria.includes('decrease') || aria.includes('trash') ||
                  aria.includes('remove') || aria.includes('note') ||
                  aria.includes('essential') || aria.includes('close') ||
                  aria.includes('navigate') || aria.includes('back')) continue;
              var rect = btn.getBoundingClientRect();
              return { found: true, method: 'svg-button', aria: aria,
                       x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
            }

            // Fallback: find "Case • SKU" text, walk up to container, find + button
            var allElements = document.querySelectorAll('*');
            for (var el of allElements) {
              if (el.children.length > 3) continue;
              if (el.offsetParent === null) continue;
              var text = (el.textContent || '').trim();
              var match = text.match(/^(?:Case|Each|Piece|Pack|Bag|Box|Unit)\\s*[•·]\\s*(\\d+)$/);
              if (match && match[1] === targetSku) {
                var container = el;
                for (var j = 0; j < 15 && container; j++) {
                  container = container.parentElement;
                  if (!container) break;
                  var btns = container.querySelectorAll('button, [role="button"]');
                  for (var btn of btns) {
                    if (btn.offsetParent === null) continue;
                    var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                    if (aria.includes('increase') || aria.includes('add')) {
                      var rect = btn.getBoundingClientRect();
                      return { found: true, method: 'sku-walk-up', aria: aria,
                               x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
                    }
                  }
                }
              }
            }

            // Log available buttons for debugging
            var btnList = [];
            for (var btn of buttons) {
              if (btn.offsetParent === null) continue;
              btnList.push({
                aria: (btn.getAttribute('aria-label') || ''),
                text: (btn.textContent || '').trim().substring(0, 30),
                hasSvg: !!btn.querySelector('svg')
              });
            }
            return { found: false, reason: 'No add/increase button found',
                     available_buttons: btnList.slice(0, 10) };
          })()
        JS

        logger.info "[PremiereProduceOne] click_modal_add_button attempt #{attempt + 1}: #{result.inspect}"

        if result && result['found']
          x = result['x'].to_f
          y = result['y'].to_f
          logger.info "[PremiereProduceOne] Clicking + button at (#{x.round(1)}, #{y.round(1)}) via CDP mouse — #{result['method']}"
          browser.mouse.click(x: x, y: y)
          sleep 0.5
          return true
        end

        sleep 1
      end

      false
    end

    # Close the product detail modal using real CDP events (React Native Web ignores JS-based events)
    def close_product_modal_ppo
      # Strategy 1: Find close/X/back button and CDP mouse click it
      close_btn = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('button, [role="button"]');
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
            var text = (btn.textContent || '').trim().toLowerCase();
            if (aria.includes('close') || aria.includes('back') || aria.includes('dismiss') ||
                aria === 'x' || text === '×' || text === 'x' || text === 'close') {
              var rect = btn.getBoundingClientRect();
              return { found: true, x: rect.left + rect.width / 2, y: rect.top + rect.height / 2,
                       aria: aria, text: text };
            }
          }
          return { found: false };
        })()
      JS

      if close_btn && close_btn['found']
        logger.debug "[PremiereProduceOne] Closing modal via close button at (#{close_btn['x']}, #{close_btn['y']})"
        browser.mouse.click(x: close_btn['x'].to_f, y: close_btn['y'].to_f)
        sleep 0.5
      end

      # Strategy 2: Click outside the modal (far left edge where backdrop is)
      # React modals typically have a backdrop that closes on click
      has_modal = browser.evaluate("document.querySelectorAll('[role=\"dialog\"], [aria-modal=\"true\"]').length > 0")
      if has_modal
        logger.debug '[PremiereProduceOne] Modal still open, clicking backdrop at (10, 400)'
        browser.mouse.click(x: 10.0, y: 400.0)
        sleep 0.5
      end

      # Strategy 3: Navigate back to close any overlay
      has_modal = browser.evaluate("document.querySelectorAll('[role=\"dialog\"], [aria-modal=\"true\"]').length > 0")
      if has_modal
        logger.debug '[PremiereProduceOne] Modal still open, pressing Escape via CDP keyboard'
        # Send real Escape via CDP keyboard API
        begin
          browser.keyboard.type(:Escape)
        rescue StandardError
          # Fallback to JS dispatch
          browser.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', bubbles: true, keyCode: 27 }));")
        end
        sleep 0.5
      end

      # Strategy 4: Navigate away and back to force-close any modal
      has_modal = browser.evaluate("document.querySelectorAll('[role=\"dialog\"], [aria-modal=\"true\"]').length > 0")
      if has_modal
        logger.debug '[PremiereProduceOne] Modal STILL open after 3 strategies, navigating away to force close'
        browser.evaluate("window.history.back()")
        sleep 1
        wait_for_react_render(timeout: 5)
      end
    end

    # Aggressively dismiss any modal/overlay/popup that may be covering the page.
    # Unlike close_product_modal_ppo (which only checks role="dialog"/aria-modal),
    # this also detects Pepper's product detail modals which use a full-screen
    # backdrop div without standard ARIA modal attributes.
    def dismiss_all_modals_ppo
      # Detect if anything is overlaying the page by checking what's at the center
      # of where the delivery dropdown typically lives (top-right area of cart panel)
      modal_state = browser.evaluate(<<~JS)
        (function() {
          // Check for any visible close/X buttons — strong signal a modal is open
          // IMPORTANT: Exclude buttons inside the Order Summary sidebar
          var closeButtons = [];
          var buttons = document.querySelectorAll('button, [role="button"], div[class*="css-"]');
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            // Skip buttons inside the Order Summary sidebar
            var ancestor = btn.closest('[role="dialog"], [aria-modal="true"]');
            if (ancestor) {
              var ancestorText = (ancestor.textContent || '').substring(0, 500);
              if (/place.*order|estimated total|order summary|submit order|view order/i.test(ancestorText)) continue;
            }
            var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
            var text = (btn.textContent || '').trim();
            // Match close/X buttons: aria-label, single × character, or SVG-only small button
            var isClose = aria.includes('close') || aria.includes('dismiss') || aria === 'x' ||
                          text === '×' || text === 'X' || text === 'x' || text.toLowerCase() === 'close';
            if (!isClose && btn.querySelector('svg') && !text.trim()) {
              // Small button with only an SVG (likely X icon) — check size
              var rect = btn.getBoundingClientRect();
              if (rect.width < 60 && rect.height < 60 && rect.width > 10) {
                isClose = true;
              }
            }
            if (isClose) {
              var rect = btn.getBoundingClientRect();
              closeButtons.push({ x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, aria: aria, text: text.substring(0, 20) });
            }
          }

          // Check for standard ARIA modals — but NOT the Order Summary sidebar
          var ariaModals = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
          var hasAriaModal = false;
          for (var m of ariaModals) {
            if (m.offsetParent === null) continue;
            var mText = (m.textContent || '').substring(0, 1000);
            // Skip the Order Summary sidebar (has cart/order content)
            if (/place.*order|estimated total|order summary|submit order|view order/i.test(mText)) continue;
            hasAriaModal = true;
            break;
          }

          // Check for product detail modal overlays (NOT the Order Summary sidebar)
          // A product modal has: position:fixed, covers viewport, AND contains
          // product-specific content like "Fulfillment history" or "Legal Disclaimer"
          // but NOT cart/order content like "Place order", "Estimated Total", "Order Summary"
          var hasFullScreenOverlay = false;
          var overlays = document.querySelectorAll('div[class*="css-"]');
          for (var ov of overlays) {
            if (ov.offsetParent === null) continue;
            var style = window.getComputedStyle(ov);
            if (style.position === 'fixed' || style.position === 'absolute') {
              var rect = ov.getBoundingClientRect();
              if (rect.width > window.innerWidth * 0.8 && rect.height > window.innerHeight * 0.8) {
                var ovText = (ov.textContent || '').substring(0, 1000);
                // Positive signals: product detail modal content
                var isProductModal = /fulfillment history|legal disclaimer/i.test(ovText);
                // Negative signals: this is the cart/order sidebar, not a modal
                var isCartSidebar = /place.*order|estimated total|order summary|submit order/i.test(ovText);
                if (isProductModal && !isCartSidebar) {
                  hasFullScreenOverlay = true;
                  break;
                }
              }
            }
          }

          return {
            hasAriaModal: hasAriaModal,
            hasFullScreenOverlay: hasFullScreenOverlay,
            closeButtons: closeButtons.slice(0, 5),
            needsDismissal: hasAriaModal || hasFullScreenOverlay
          };
        })()
      JS

      return unless modal_state && modal_state['needsDismissal']

      logger.info "[PremiereProduceOne] Modal detected — dismissing (aria=#{modal_state['hasAriaModal']}, overlay=#{modal_state['hasFullScreenOverlay']}, closeButtons=#{modal_state['closeButtons']&.length})"

      # Strategy 1: Click the first close button found
      if modal_state['closeButtons']&.any?
        btn = modal_state['closeButtons'].first
        logger.info "[PremiereProduceOne] Clicking close button at (#{btn['x']}, #{btn['y']}) aria=#{btn['aria']}"
        browser.mouse.click(x: btn['x'].to_f, y: btn['y'].to_f)
        sleep 1
        return
      end

      # Strategy 2: Press Escape
      logger.info '[PremiereProduceOne] No close button, pressing Escape'
      begin
        browser.keyboard.type(:Escape)
      rescue StandardError
        browser.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', bubbles: true, keyCode: 27 }));")
      end
      sleep 1
    end

    def wait_for_any_selector(*selectors, timeout: 10)
      options = selectors.last.is_a?(Hash) ? selectors.pop : {}
      timeout_val = options[:timeout] || timeout

      start_time = Time.current
      while Time.current - start_time < timeout_val
        selectors.each do |sel|
          return true if browser.at_css(sel)
        end
        sleep 0.3
      end

      raise ScrapingError, "None of selectors found: #{selectors.join(', ')}"
    end

    public

    def browser_checkout(dry_run: false)
      logger.info "[PremiereProduceOne] checkout starting (dry_run=#{dry_run})"
      ensure_order_browser!

      begin
        # Step 1: Navigate to cart page
        navigate_to_cart_page_ppo

        # Step 2: Extract cart data
        cart_data = extract_cart_data_ppo
        logger.info "[PremiereProduceOne] Cart: #{cart_data[:item_count]} items, subtotal=#{cart_data[:subtotal]}"

        # Step 3: Validate cart — Pepper may not expose item count via inputs,
        # so also check subtotal as an indicator the cart has items.
        if cart_data[:item_count] == 0 && cart_data[:subtotal] == 0
          raise ScrapingError, 'Cart is empty'
        end
        if cart_data[:item_count] == 0 && cart_data[:subtotal] > 0
          logger.warn "[PremiereProduceOne] item_count=0 but subtotal=$#{cart_data[:subtotal]} — Pepper may not expose qty inputs. Proceeding."
        end

        # Step 4: Check for unavailable items
        if cart_data[:unavailable_items].any?
          raise ItemUnavailableError.new(
            "#{cart_data[:unavailable_items].count} item(s) are unavailable",
            items: cart_data[:unavailable_items]
          )
        end

        # Step 5: Navigate to checkout/review page
        proceed_to_checkout_page_ppo

        # Step 5.5: Select delivery date on the REVIEW page (Order Summary panel)
        # The cart page has a "Cutoff: ... | DELIVERY Mar 16" label but it doesn't
        # open a date picker — only the review page's Order Summary panel does.
        # Order 367 confirmed this: the calendar only opened on the review page.
        select_delivery_date_ppo if @target_delivery_date

        # Step 5.6: Reopen the Order Summary sidebar if it closed
        # The calendar modal causes the sidebar to close. We need the sidebar
        # open again for both checkout data extraction and the Place Order button.
        if @target_delivery_date
          sidebar_open = browser.evaluate(<<~JS)
            (function() {
              var placeOrderRegex = /place.*order/i;
              var buttons = document.querySelectorAll('button, [role="button"]');
              for (var btn of buttons) {
                if (btn.offsetParent === null) continue;
                var text = (btn.textContent || '').trim().toLowerCase();
                if (placeOrderRegex.test(text)) return true;
              }
              return false;
            })()
          JS

          unless sidebar_open
            logger.info '[PremiereProduceOne] Order Summary sidebar closed after date selection — reopening'
            proceed_to_checkout_page_ppo
          end
        end

        # Step 6: Extract checkout data
        checkout_data = extract_checkout_data_ppo
        logger.info "[PremiereProduceOne] Checkout: total=#{checkout_data[:total]}, delivery=#{checkout_data[:delivery_date]}"

        # ═══════════════════════════════════════════
        # ═══ SAFETY GATE — DRY RUN CHECK ══════════
        # ═══════════════════════════════════════════
        if dry_run
          logger.info "[PremiereProduceOne] DRY RUN COMPLETE — stopping before final submit"
          logger.info "[PremiereProduceOne] Would have placed order: total=#{checkout_data[:total]}"

          return {
            confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
            total: checkout_data[:total] || cart_data[:subtotal],
            delivery_date: checkout_data[:delivery_date],
            dry_run: true,
            cart_items: cart_data[:items],
            checkout_summary: checkout_data
          }
        end

        # Step 7: LIVE ORDER — Click final submit
        logger.warn "[PremiereProduceOne] PLACING LIVE ORDER — clicking submit"
        click_place_order_button_ppo

        # Step 8: Wait for confirmation
        confirmation = wait_for_order_confirmation_ppo

        logger.info "[PremiereProduceOne] Order placed: #{confirmation[:confirmation_number]}"
        confirmation
      ensure
        close_order_browser!
      end
    end

    # ── Persistent browser for ordering flow ──
    # Keeps one browser alive across clear_cart → add_to_cart → checkout
    # so cart state is preserved. Matches the US Foods / WCW pattern.
    def ensure_order_browser!
      return if @browser # Already have an open browser

      logger.info '[PremiereProduceOne] Starting order browser (persistent for checkout flow)'

      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'
      headless_mode = false if Rails.env.development?

      browser_opts = {
        headless: headless_mode,
        timeout: 420, # 7 minutes for 2FA wait
        process_timeout: 60,
        window_size: [1920, 1080]
      }

      if headless_mode
        browser_opts[:browser_options] = {
          "no-sandbox": true,
          "disable-gpu": true,
          "disable-dev-shm-usage": true
        }
      else
        browser_opts[:browser_options] = {
          "no-sandbox": true,
          "start-maximized": true
        }
        browser_opts[:headless] = false
      end

      browser_opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?

      @browser = Ferrum::Browser.new(**browser_opts)
      setup_network_interception(@browser)

      # Login (wrapped in rescue to close browser on failure)
      begin
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          wait_for_react_render(timeout: 15)
        end

        unless logged_in?
          logger.info '[PremiereProduceOne] Order browser not logged in, performing login'
          perform_login_steps

          if two_fa_page?
            code = wait_for_user_code(attempt: 1, resent: false)
            raise AuthenticationError, 'Verification timed out' unless code

            type_code_and_submit(code)
            sleep 5
            wait_for_page_load

            raise AuthenticationError, 'Login failed after 2FA' unless logged_in?

            credential.mark_active!
            mark_2fa_request_verified!
            TwoFactorChannel.broadcast_to(credential.user, { type: 'code_result', success: true })
          end

          save_session
        end
      rescue => e
        close_order_browser!
        raise
      end

      logger.info '[PremiereProduceOne] Order browser ready'
    end

    def close_order_browser!
      save_session if @browser
      @browser&.quit
      @browser = nil
      close_api_client
    rescue StandardError => e
      logger.debug "[PremiereProduceOne] Error closing order browser: #{e.message}"
      @browser = nil
    end

    def browser_clear_cart
      logger.info '[PremiereProduceOne] Clearing cart...'
      ensure_order_browser!

        # IMPORTANT: In Pepper, /cart shows the Order Guide (NOT the shopping cart).
        # The actual cart is a MODAL/PANEL opened by clicking the "View Order" button
        # (cart icon with $ total) in the top-right nav bar.
        # We must click that button via CDP mouse to open the cart panel.

        # Check if "View Order" button exists (indicates items in cart).
        # The cart total in the nav bar may load asynchronously after React renders,
        # so retry several times with pauses to avoid a false "cart empty" result.
        view_order = nil
        5.times do |check_attempt|
          view_order = browser.evaluate(<<~JS)
            (function() {
              var buttons = document.querySelectorAll('button, [role="button"]');
              for (var btn of buttons) {
                if (btn.offsetParent === null) continue;
                var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                if (aria.includes('view order')) {
                  var text = (btn.textContent || '').trim();
                  var rect = btn.getBoundingClientRect();
                  return { found: true, text: text, aria: aria,
                           x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
                }
              }
              return { found: false };
            })()
          JS

          break if view_order && view_order['found']

          if check_attempt < 4
            logger.info "[PremiereProduceOne] View Order button not found yet (attempt #{check_attempt + 1}/5), waiting..."
            sleep 1
            wait_for_react_render(timeout: 5)
          end
        end

        if !view_order || !view_order['found']
          logger.info '[PremiereProduceOne] No "View Order" button found after 5 checks — cart appears empty'
          save_session
          return
        end

        logger.info "[PremiereProduceOne] Found View Order button: #{view_order['text'].inspect} at (#{view_order['x']}, #{view_order['y']})"

        # Click the View Order button to open the cart panel
        browser.mouse.click(x: view_order['x'].to_f, y: view_order['y'].to_f)
        sleep 1
        wait_for_react_render(timeout: 5)

        # Verify cart panel opened — should now have decrease/trash buttons
        page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
        logger.info "[PremiereProduceOne] Cart panel text (first 300): #{page_text[0..300]}"

        # Check if cart panel shows empty
        if page_text.match?(/cart is empty|no items|your cart is empty/i)
          logger.info '[PremiereProduceOne] Cart panel shows empty'
          save_session
          return
        end

        # ── Identify the cart panel container ──
        # The View Order click opens a side panel/overlay. We must scope all
        # button searches to this panel to avoid clicking order guide buttons underneath.
        # The panel is typically: [role="dialog"], a right-aligned fixed/absolute container,
        # or the element containing "Place Order" / cart total text.
        cart_panel_selector = browser.evaluate(<<~JS)
          (function() {
            // Strategy 1: dialog/modal role
            var dialogs = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
            if (dialogs.length > 0) return { selector: '[role="dialog"], [aria-modal="true"]', method: 'dialog-role' };

            // Strategy 2: fixed/absolute positioned panel on right side of screen
            var allEls = document.querySelectorAll('div, section, aside');
            for (var el of allEls) {
              if (el.offsetParent === null && el.style.display !== 'none') continue;
              var style = window.getComputedStyle(el);
              if ((style.position === 'fixed' || style.position === 'absolute') &&
                  el.getBoundingClientRect().right > window.innerWidth * 0.5 &&
                  el.getBoundingClientRect().width > 200 &&
                  el.getBoundingClientRect().width < window.innerWidth * 0.8) {
                var text = (el.textContent || '').toLowerCase();
                if (text.includes('place order') || text.includes('view order') || text.includes('subtotal')) {
                  el.setAttribute('data-cart-panel', 'true');
                  return { selector: '[data-cart-panel="true"]', method: 'fixed-panel' };
                }
              }
            }

            // Strategy 3: find container with "Place Order" button text
            var placeOrderBtns = document.querySelectorAll('button, [role="button"]');
            for (var btn of placeOrderBtns) {
              if (btn.offsetParent === null) continue;
              var btnText = (btn.textContent || '').trim().toLowerCase();
              if (btnText.includes('place order')) {
                // Walk up to a significant container
                var container = btn;
                for (var i = 0; i < 10 && container.parentElement; i++) {
                  container = container.parentElement;
                  var rect = container.getBoundingClientRect();
                  if (rect.height > 300 && rect.width > 200 && rect.width < window.innerWidth * 0.8) {
                    container.setAttribute('data-cart-panel', 'true');
                    return { selector: '[data-cart-panel="true"]', method: 'place-order-ancestor' };
                  }
                }
              }
            }

            // Fallback: search entire document
            return { selector: null, method: 'fallback-full-page' };
          })()
        JS

        panel_sel = cart_panel_selector&.dig('selector')
        logger.info "[PremiereProduceOne] Cart panel detection: #{cart_panel_selector.inspect}"

        # Log what buttons are available in the cart panel
        cart_buttons = browser.evaluate(<<~JS)
          (function() {
            var scope = #{panel_sel ? "document.querySelector('#{panel_sel}')" : 'document'};
            if (!scope) scope = document;
            var results = [];
            var buttons = scope.querySelectorAll('button, [role="button"]');
            for (var btn of buttons) {
              if (btn.offsetParent === null) continue;
              var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
              if (aria.includes('decrease') || aria.includes('increase') ||
                  aria.includes('trash') || aria.includes('remove') || aria.includes('delete')) {
                results.push(aria);
              }
            }
            return { total: buttons.length, cart_buttons: results.slice(0, 20) };
          })()
        JS
        logger.info "[PremiereProduceOne] Cart panel buttons: #{cart_buttons.inspect}"

        # ── Pepper cart removal strategy (CDP mouse clicks) ──
        # Scoped to the cart panel to avoid hitting order guide buttons underneath.
        #
        # PRIMARY: Hover over each cart item row to reveal hidden trash icon, then
        # click it — removes the item in one click regardless of quantity.
        # FALLBACK: If hover-trash fails, use decrease/trash buttons directly.
        #
        # CRITICAL: React Native Web Pressable components ignore el.click().
        # We MUST use Ferrum's browser.mouse.click(x:, y:) for real CDP mouse events.
        #
        # SAFETY: We NEVER click "Increase quantity".

        removed_count = 0
        total_clicks = 0
        max_total_clicks = 200 # safety limit (much lower now — hover-trash is O(n) not O(n*qty))
        stale_rounds = 0
        hover_trash_failed = false

        loop do
          break if total_clicks >= max_total_clicks

          # ── Strategy 1: Hover to reveal trash icon ──
          # PPO shows a trash icon on hover that removes the entire item regardless of qty.
          unless hover_trash_failed
            row_result = browser.evaluate(<<~JS)
              (function() {
                var scope = #{panel_sel ? "document.querySelector('#{panel_sel}')" : 'document'};
                if (!scope) scope = document;

                // Find cart item rows — look for elements with qty controls or product info
                // Cart items typically have a container with price/qty text
                var candidates = scope.querySelectorAll('[role="button"], [data-testid], div, li');
                for (var el of candidates) {
                  if (el.offsetParent === null) continue;
                  var rect = el.getBoundingClientRect();
                  // Cart item rows are typically 50-150px tall, within the panel
                  if (rect.height < 40 || rect.height > 200) continue;
                  if (rect.width < 150) continue;

                  // Check if this row has qty-related content (decrease/increase buttons or qty text)
                  var innerButtons = el.querySelectorAll('button, [role="button"]');
                  var hasQtyControl = false;
                  for (var btn of innerButtons) {
                    var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                    if (aria.includes('decrease') || aria.includes('increase')) {
                      hasQtyControl = true;
                      break;
                    }
                  }
                  if (!hasQtyControl) continue;

                  // Found a cart item row — return its center for hovering
                  el.scrollIntoView({ behavior: 'instant', block: 'center' });
                  var newRect = el.getBoundingClientRect();
                  return {
                    found: true, type: 'item-row',
                    x: newRect.left + newRect.width / 2,
                    y: newRect.top + newRect.height / 2,
                    width: newRect.width, height: newRect.height
                  };
                }
                return { found: false, type: 'no-item-rows' };
              })()
            JS

            if row_result && row_result['found']
              # Hover over the item row to reveal the trash icon
              browser.mouse.move(x: row_result['x'].to_f, y: row_result['y'].to_f)
              sleep 0.4 # Wait for hover state / trash icon to appear

              # Look for the trash icon that appeared on hover
              trash_result = browser.evaluate(<<~JS)
                (function() {
                  var scope = #{panel_sel ? "document.querySelector('#{panel_sel}')" : 'document'};
                  if (!scope) scope = document;
                  var buttons = scope.querySelectorAll('button, [role="button"]');
                  for (var btn of buttons) {
                    if (btn.offsetParent === null) continue;
                    var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                    var btnText = (btn.textContent || '').trim().toLowerCase();
                    if (aria.includes('trash') || aria.includes('remove') || aria.includes('delete') ||
                        btnText === 'remove' || btnText === 'delete' || btnText === '×' || btnText === 'x') {
                      var rect = btn.getBoundingClientRect();
                      // Only match if this trash button is near the hovered row
                      var rowY = #{row_result['y']};
                      if (Math.abs(rect.top + rect.height/2 - rowY) < 80) {
                        return {
                          found: true, aria: aria, text: btnText,
                          x: rect.left + rect.width / 2,
                          y: rect.top + rect.height / 2
                        };
                      }
                    }
                  }
                  return { found: false };
                })()
              JS

              if trash_result && trash_result['found']
                total_clicks += 1
                removed_count += 1
                logger.info "[PremiereProduceOne] Hover-trash: removed item #{removed_count} at (#{trash_result['x']}, #{trash_result['y']}) (click ##{total_clicks})"
                browser.mouse.click(x: trash_result['x'].to_f, y: trash_result['y'].to_f)
                sleep 0.3
                confirm_pepper_modal
                sleep 0.3
                next
              else
                # Trash didn't appear on hover — fall through to decrease-button strategy
                logger.info "[PremiereProduceOne] Hover-trash: no trash icon appeared on hover, falling back to decrease buttons"
                hover_trash_failed = true
              end
            end
          end

          # ── Strategy 2 (fallback): Click decrease/trash buttons directly ──
          result = browser.evaluate(<<~JS)
            (function() {
              var scope = #{panel_sel ? "document.querySelector('#{panel_sel}')" : 'document'};
              if (!scope) scope = document;
              var buttons = scope.querySelectorAll('button, [role="button"]');
              for (var btn of buttons) {
                if (btn.offsetParent === null) continue;
                var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                var btnText = (btn.textContent || '').trim().toLowerCase();

                // Match: trash/remove/delete FIRST (removes item entirely at qty=1)
                if (aria.includes('trash') || aria.includes('remove') || aria.includes('delete') ||
                    btnText === 'remove' || btnText === 'delete') {
                  btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                  var rect = btn.getBoundingClientRect();
                  return {
                    found: true, aria: aria, btnText: btnText, is_trash: true,
                    x: rect.left + rect.width / 2,
                    y: rect.top + rect.height / 2
                  };
                }

                // Then "Decrease quantity" (the minus button)
                if (aria.includes('decrease')) {
                  btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                  var rect = btn.getBoundingClientRect();
                  return {
                    found: true, aria: aria, btnText: btnText, is_trash: false,
                    x: rect.left + rect.width / 2,
                    y: rect.top + rect.height / 2
                  };
                }
              }
              return { found: false, reason: 'no decrease/trash buttons in cart panel' };
            })()
          JS

          # No decrease/trash buttons left → cart is empty
          if result.nil? || !result['found']
            stale_rounds += 1
            if stale_rounds >= 3
              logger.info "[PremiereProduceOne] No decrease/trash buttons found after #{stale_rounds} checks — cart should be empty (#{removed_count} items removed, #{total_clicks} clicks)"
              break
            end

            sleep 0.5
            next
          end

          stale_rounds = 0
          total_clicks += 1

          is_trash = result['is_trash']
          aria = result['aria'] || ''

          if is_trash
            removed_count += 1
            logger.info "[PremiereProduceOne] Removed item #{removed_count} via trash at (#{result['x']}, #{result['y']}) (click ##{total_clicks})"
          elsif total_clicks <= 5 || total_clicks % 20 == 0
            logger.info "[PremiereProduceOne] Decreasing qty at (#{result['x']}, #{result['y']}) (click ##{total_clicks}, aria=#{aria})"
          end

          # CDP mouse click — the ONLY way to trigger React Native Web Pressable
          browser.mouse.click(x: result['x'].to_f, y: result['y'].to_f)
          sleep 0.2

          # Handle any confirmation modal after trash click
          if is_trash
            sleep 0.3
            confirm_pepper_modal
            sleep 0.3
          end
        end

        logger.info "[PremiereProduceOne] Cart clearing complete: #{removed_count} items removed, #{total_clicks} total clicks"

        # Verify cart is empty — retry clearing if items remain
        max_verify_attempts = 3
        max_verify_attempts.times do |attempt|
          sleep 1
          page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''

          if page_text.match?(/cart is empty|no items|your cart is empty/i)
            logger.info '[PremiereProduceOne] Cart confirmed empty!'
            save_session
            return
          end

          # Check if the "View Order" button still shows a dollar amount (items remain)
          view_order_check = browser.evaluate(<<~JS)
            (function() {
              var buttons = document.querySelectorAll('button, [role="button"]');
              for (var btn of buttons) {
                if (btn.offsetParent === null) continue;
                var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                if (aria.includes('view order')) {
                  var text = (btn.textContent || '').trim();
                  return { found: true, text: text, has_price: /\\$\\d/.test(text) };
                }
              }
              return { found: false };
            })()
          JS

          if view_order_check && view_order_check['found'] && view_order_check['has_price']
            logger.warn "[PremiereProduceOne] Cart still has items (View Order shows: #{view_order_check['text'].inspect}), retry #{attempt + 1}/#{max_verify_attempts}"

            if attempt < max_verify_attempts - 1
              # Re-open cart panel and try clearing again
              browser.mouse.click(x: view_order_check['x']&.to_f || 0, y: view_order_check['y']&.to_f || 0) rescue nil
              sleep 1
              # Re-run the removal loop scoped to cart panel
              20.times do
                btn = browser.evaluate(<<~JS)
                  (function() {
                    var scope = #{panel_sel ? "document.querySelector('#{panel_sel}')" : 'document'};
                    if (!scope) scope = document;
                    var buttons = scope.querySelectorAll('button, [role="button"]');
                    for (var btn of buttons) {
                      if (btn.offsetParent === null) continue;
                      var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                      if (aria.includes('decrease') || aria.includes('trash') ||
                          aria.includes('remove') || aria.includes('delete')) {
                        btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                        var rect = btn.getBoundingClientRect();
                        return { found: true, x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
                      }
                    }
                    return { found: false };
                  })()
                JS
                break if btn.nil? || !btn['found']
                browser.mouse.click(x: btn['x'].to_f, y: btn['y'].to_f)
                sleep 0.3
              end
              next
            end

            # Final attempt failed — raise so we don't add items on top of a dirty cart
            raise ScrapingError, "Failed to clear cart after #{max_verify_attempts} attempts — items remain (#{view_order_check['text'].inspect})"
          else
            # No View Order button with price — cart is likely empty
            logger.info '[PremiereProduceOne] Cart appears cleared (no View Order button with price found)'
            save_session
            return
          end
        end

        save_session
    end

    # Discover the button layout for a single cart item.
    # Returns info about how many buttons per item and their roles.
    def discover_cart_item_buttons
      browser.evaluate(<<~JS)
        (function() {
          // Find first SKU element
          var allEls = document.querySelectorAll('*');
          for (var el of allEls) {
            if (el.children.length > 5 || el.offsetParent === null) continue;
            var text = (el.textContent || '').trim();
            if (!/^(?:Case|Each|Piece)\\s*[•·]\\s*\\d{3,}$/.test(text)) continue;

            // Walk up to item container
            var container = el;
            for (var i = 0; i < 10 && container; i++) {
              container = container.parentElement;
              if (!container) break;
              var buttons = container.querySelectorAll('button');
              if (buttons.length >= 3) break;
            }
            if (!container) continue;

            var buttons = container.querySelectorAll('button');
            var info = [];
            for (var btn of buttons) {
              if (btn.offsetParent === null) continue;
              info.push({
                text: (btn.textContent || '').trim().substring(0, 30),
                has_svg: !!btn.querySelector('svg'),
                classes: (btn.className || '').substring(0, 60),
                aria: (btn.getAttribute('aria-label') || '').substring(0, 30)
              });
            }
            return { sku_text: text, button_count: info.length, buttons: info };
          }
          return null;
        })()
      JS
    end

    # Click "Yes" / "Confirm" / "OK" in Pepper confirmation modals.
    # Uses CDP mouse click since React Native Web Pressable ignores el.click().
    def confirm_pepper_modal
      result = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('button, [role="button"]');
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            var text = (btn.textContent || btn.innerText || '').trim().toLowerCase();
            if (text === 'yes' || text === 'confirm' || text === 'clear' || text === 'ok' ||
                text === 'remove' || text === 'delete') {
              var rect = btn.getBoundingClientRect();
              return { found: true, text: text,
                       x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
            }
          }
          return { found: false };
        })()
      JS

      if result && result['found']
        logger.debug "[PremiereProduceOne] Confirming modal: clicking '#{result['text']}' at (#{result['x']}, #{result['y']})"
        browser.mouse.click(x: result['x'].to_f, y: result['y'].to_f)
        sleep 0.3
      end
    end

    protected

    # PPO uses a passwordless login: enter email → receive code → enter code.
    # This method navigates to the site, enters the email, and clicks Continue.
    # After this the site shows a "Verification code" page (2FA).
    def perform_login_steps
      navigate_to(LOGIN_URL)
      sleep 3

      # Step 1: Click "Sign in" on the landing page
      click_button_by_text('sign in')
      sleep 2

      # Step 2: Switch to email tab (PPO defaults to phone number)
      begin
        browser.evaluate('(function() { var tabs = document.querySelectorAll("[aria-selected]"); for (var i = 0; i < tabs.length; i++) { if (tabs[i].getAttribute("aria-selected") === "false") { tabs[i].click(); return true; } } return false; })()')
      rescue StandardError
        nil
      end
      sleep 1

      # Step 3: Enter email in the email input (using React-compatible setter)
      email_input = browser.at_css("input[type='email']")
      if email_input
        email_input.focus
        set_react_input_value(email_input, credential.username)
      else
        logger.warn '[PremiereProduceOne] Email input not found on login page'
        raise AuthenticationError, 'Could not find email input on login page'
      end

      sleep 1

      # Step 4: Click Continue to submit email and trigger verification code
      click_button_by_text('continue')
      sleep 3
      wait_for_page_load

      # Check for rate limiting
      body_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 2000)')
      rescue StandardError
        ''
      end
      return unless body_text.match?(/maximum.*attempts|too many.*attempts|try again.*minutes|rate.?limit/i)

      rate_msg = body_text.scan(/maximum.*?minutes\.?|too many.*?minutes\.?|try again.*?minutes\.?/i).first
      error_msg = rate_msg&.strip || 'Too many login attempts. Please wait and try again.'
      credential.mark_failed!(error_msg)
      raise AuthenticationError, error_msg
    end

    # PPO's Next.js / React Native Web app fails to hydrate when fonts are
    # blocked — the base interception is too aggressive for SPAs that depend
    # on icon fonts to render. Block images and analytics but allow fonts.
    def setup_network_interception(browser_instance)
      browser_instance.network.intercept
      browser_instance.on(:request) do |request|
        url = request.url
        if url.match?(/\.(jpg|jpeg|png|gif|webp|ico)(\?|$)/i) ||
           url.include?('adobedtm.com') ||
           url.include?('analytics') ||
           url.include?('google-analytics') ||
           url.include?('googletagmanager') ||
           url.include?('doubleclick') ||
           url.include?('facebook.com/tr') ||
           url.include?('hotjar')
          request.abort
        else
          request.continue
        end
      end
    rescue StandardError => e
      logger.warn "[PremiereProduceOne] Network interception setup failed: #{e.message}"
    end

    # Set a value on a React controlled input using the native HTMLInputElement
    # value setter. React overrides the input's value property with its own getter/setter,
    # so setting .value directly doesn't trigger React's onChange. By calling the NATIVE
    # setter from HTMLInputElement.prototype, we bypass React's override, then dispatch
    # the proper events so React picks up the change.
    def set_react_input_value(input_node, value)
      safe_value = js_string(value)

      js = <<~JS
        (function(el) {
          var val = #{safe_value};
          // Clear first
          var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          nativeSetter.call(el, '');
          el.dispatchEvent(new Event('input', { bubbles: true }));

          // Set the actual value
          nativeSetter.call(el, val);

          // Dispatch events that React listens for
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));

          return el.value;
        })(this)
      JS

      result = input_node.evaluate(js)
      logger.info "[PremiereProduceOne] React input value set, confirmed: '#{result}'"
      result
    rescue StandardError => e
      logger.warn "[PremiereProduceOne] React setter failed (#{e.message}), falling back to character-by-character typing"
      # Fallback: type character by character which generates real keyboard events
      begin
        input_node.focus
        # Triple-click to select all, then delete
        input_node.evaluate('this.select()')
        browser.keyboard.type(:Backspace)
        sleep 0.2
        # Type each character individually to trigger React key events
        value.each_char do |char|
          browser.keyboard.type(char)
          sleep 0.05
        end
      rescue StandardError => e2
        logger.error "[PremiereProduceOne] Character typing also failed: #{e2.message}"
        raise
      end
    end

    private

    # Wait for PPO's React SPA to fully render after page load / session restore.
    # The SPA needs time to hydrate and render logged-in UI elements.
    def wait_for_react_render(timeout: 10)
      start = Time.current
      loop do
        # Check if React has rendered meaningful content
        body_text = begin
          browser.evaluate('document.body?.innerText?.substring(0, 2000)')
        rescue StandardError
          ''
        end
        has_content = body_text.length > 100
        has_logged_in_indicators = body_text.match?(/order guide|add to cart|my orders|explore catalog|log out|become a customer/i)
        has_2fa_indicators = body_text.match?(/enter.*code|verification.*code|one.?time/i)

        if has_content && (has_logged_in_indicators || has_2fa_indicators)
          logger.info "[PremiereProduceOne] React rendered in #{(Time.current - start).round(1)}s (content_length=#{body_text.length})"
          return
        end

        if Time.current - start > timeout
          logger.warn "[PremiereProduceOne] React render timeout after #{timeout}s (content_length=#{body_text.length})"
          return
        end

        sleep 0.5
      end
    end

    # Navigate to the catalog page and ensure the search input is visible.
    # When logged in PPO goes straight to the catalog. When not logged in
    # (e.g. exploring), we click "Explore catalog". Either way, we wait
    # for the search input to appear.
    def ensure_catalog_page_loaded
      # Check if we already have the search input
      if browser.at_css("input[placeholder='Search']")
        logger.info '[PremiereProduceOne] Catalog page already loaded (search input found)'
        return
      end

      # Try clicking "Explore catalog" button (visible when not logged in or on landing)
      clicked = click_button_by_text('explore catalog')
      if clicked
        logger.info "[PremiereProduceOne] Clicked 'Explore catalog'"
        sleep 5
      end

      # Wait for the search input to appear (catalog page is loaded)
      10.times do
        break if browser.at_css("input[placeholder='Search']")

        sleep 1
      end

      unless browser.at_css("input[placeholder='Search']")
        # Last resort: refresh and try again
        navigate_to(BASE_URL)
        sleep 3
        click_button_by_text('explore catalog')
        sleep 5
      end

      logger.info "[PremiereProduceOne] Catalog page ready (search input: #{browser.at_css("input[placeholder='Search']").present?})"
    end

    # Create a 2FA request in the DB and poll for the user's code.
    # The browser stays open on the verification page while we wait.
    # Returns the code string when the user submits it, or nil on timeout.
    def wait_for_user_code(attempt: 1, resent: false)
      body_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 1000)')
      rescue StandardError
        ''
      end
      prompt = body_text.scan(/your code.*?\./i).first || 'Premiere Produce One has sent a verification code to your email. Please check your inbox and enter the code below.'
      prompt = "A new code has been sent — the previous one expired. #{prompt}" if resent

      # Create the 2FA request record
      request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        request_type: 'login',
        two_fa_type: 'email',
        prompt_message: prompt,
        status: 'pending',
        expires_at: 3.minutes.from_now
      )

      credential.update!(two_fa_enabled: true, two_fa_type: 'email')

      # Broadcast to ActionCable (may not be received, but try)
      TwoFactorChannel.broadcast_to(
        credential.user,
        {
          type: 'two_fa_required',
          request_id: request.id,
          session_token: request.session_token,
          supplier_name: credential.supplier.name,
          two_fa_type: 'email',
          prompt_message: prompt,
          expires_at: request.expires_at.iso8601
        }
      )

      logger.info "[PremiereProduceOne] Waiting for user to submit code (request ##{request.id})"

      # Poll the DB for the user's code submission.
      # The controller's submit_2fa_code action will update the request.
      timeout = 5.minutes
      poll_interval = 2.seconds
      started_at = Time.current

      loop do
        if Time.current - started_at > timeout
          request.mark_expired! if request.reload.pending?
          logger.warn '[PremiereProduceOne] Timed out waiting for code'
          return nil
        end

        request.reload

        case request.status
        when 'submitted', 'verified'
          # User submitted a code — return it
          # Note: 'verified' status is set by ActionCable/Turbo, but we still need the code
          logger.info "[PremiereProduceOne] Code received from user (status: #{request.status})"
          return request.code_submitted
        when 'cancelled'
          logger.info '[PremiereProduceOne] User cancelled 2FA'
          return nil
        when 'failed', 'expired'
          logger.info "[PremiereProduceOne] 2FA request #{request.status}"
          return nil
        end

        sleep poll_interval
      end
    end

    # Type the verification code into the input and click Continue.
    # Does NOT check the result — the caller (login) handles that.
    def type_code_and_submit(code)
      code_input = find_2fa_code_input
      unless code_input
        credential.mark_failed!('Could not find verification code input')
        raise AuthenticationError, 'Could not find verification code input'
      end

      logger.info '[PremiereProduceOne] Typing verification code into input'

      # Type character-by-character (generates real key events React responds to)
      begin
        code_input.focus
        sleep 0.2
        browser.keyboard.type([:control, 'a'])
        sleep 0.1
        browser.keyboard.type(:Backspace)
        sleep 0.2
        code.to_s.each_char do |char|
          browser.keyboard.type(char)
          sleep 0.05
        end
        actual = begin
          code_input.evaluate('this.value')
        rescue StandardError
          'unknown'
        end
        logger.info "[PremiereProduceOne] Input value after typing: '#{actual}'"

        # If typing didn't stick, use React native setter
        if actual != code.to_s
          logger.warn "[PremiereProduceOne] Typing gave '#{actual}', using nativeInputValueSetter"
          set_react_input_value(code_input, code)
        end
      rescue StandardError => e
        logger.warn "[PremiereProduceOne] Typing failed: #{e.message}, using nativeInputValueSetter"
        set_react_input_value(code_input, code)
      end

      sleep 1

      # Click the LAST Continue button (PPO SPA may have multiple in the DOM)
      continue_clicked = click_last_button_by_text('continue')
      logger.info "[PremiereProduceOne] Continue clicked: #{continue_clicked}"

      return if continue_clicked

      # Fallback: press Enter
      begin
        code_input.focus
        browser.keyboard.type(:Enter)
        logger.info '[PremiereProduceOne] Pressed Enter as fallback'
      rescue StandardError => e
        logger.warn "[PremiereProduceOne] Enter fallback failed: #{e.message}"
      end
    end

    # Helper to mark the latest submitted 2FA request as verified
    # Also checks for already-verified requests (in case TwoFactorChannel already marked it)
    def mark_2fa_request_verified!
      request = Supplier2faRequest.where(supplier_credential: credential, status: %w[submitted verified])
                                  .order(created_at: :desc).first
      request&.mark_verified! unless request&.verified?
    end

    # Helper to mark the latest submitted 2FA request as failed
    # Also checks for verified requests (in case TwoFactorChannel marked it verified but login failed after)
    def mark_2fa_request_failed!
      request = Supplier2faRequest.where(supplier_credential: credential, status: %w[submitted verified])
                                  .order(created_at: :desc).first
      request&.mark_failed! unless request&.failed?
    end

    # Navigate to the Order Guide page.
    # PPO (Pepper) is a full JS SPA — no URL changes when navigating.
    # The sidebar has links like "Order Guide", "Catalog", "Orders", etc.
    # We MUST click "Order Guide" specifically and NOT "Orders" (which shows
    # order history, a much smaller list).
    def navigate_to_order_guide
      logger.info '[PremiereProduceOne] Navigating to Order Guide'

      # Log what sidebar links we can see for debugging
      sidebar_links = browser.evaluate(<<~JS) rescue []
        (function() {
          var links = [];
          var els = document.querySelectorAll('a, button, [role="button"], [role="menuitem"], nav a, nav button, [class*="sidebar"] *, [class*="nav"] *, [class*="menu"] *');
          for (var i = 0; i < els.length; i++) {
            var text = (els[i].innerText || '').trim();
            if (text.length > 0 && text.length < 30 && !text.match(/^\\d+$/)) {
              links.push(text);
            }
          }
          // Deduplicate
          return [...new Set(links)];
        })()
      JS
      logger.info "[PremiereProduceOne] Sidebar links found: #{sidebar_links.first(15).inspect}"

      # Click "Order Guide" — prioritize exact match to avoid clicking "Orders"
      clicked = browser.evaluate(<<~JS)
        (function() {
          var els = document.querySelectorAll('a, button, [role="button"], [role="menuitem"], nav a, nav button, [class*="sidebar"] *, [class*="nav"] *, [class*="menu"] *');

          // Pass 1: exact text match "Order Guide" (case-insensitive)
          for (var i = 0; i < els.length; i++) {
            var text = (els[i].innerText || '').trim();
            if (text.toLowerCase() === 'order guide') {
              els[i].click();
              return 'exact: ' + text;
            }
          }

          // Pass 2: text starts with "Order Guide" (might have count badge)
          for (var i = 0; i < els.length; i++) {
            var text = (els[i].innerText || '').trim();
            if (text.toLowerCase().startsWith('order guide')) {
              els[i].click();
              return 'startsWith: ' + text;
            }
          }

          // Pass 3: aria-label match
          for (var i = 0; i < els.length; i++) {
            var label = (els[i].getAttribute('aria-label') || '').toLowerCase();
            if (label === 'order guide' || label.startsWith('order guide')) {
              els[i].click();
              return 'aria: ' + els[i].getAttribute('aria-label');
            }
          }

          return false;
        })()
      JS

      if clicked
        logger.info "[PremiereProduceOne] Clicked: #{clicked}"
        sleep 4
        wait_for_react_render(timeout: 15)

        # Verify we landed on the Order Guide (should have product SKU patterns)
        page_sample = browser.evaluate('document.body?.innerText?.substring(0, 3000)') rescue ''
        has_products = page_sample.match?(/[A-Za-z]+\s*[•·]\s*\d{3,}/)
        has_order_guide_heading = page_sample.match?(/order guide/i)
        logger.info "[PremiereProduceOne] Page verification — products: #{has_products}, heading: #{has_order_guide_heading}"

        unless has_products || has_order_guide_heading
          logger.warn "[PremiereProduceOne] Page does not look like Order Guide. First 500 chars: #{page_sample[0..500]}"
        end
      else
        logger.warn "[PremiereProduceOne] Could not find 'Order Guide' link in sidebar!"
      end
    end

    # Discover multiple order guides via the dropdown chevron.
    # Returns array of { name:, remote_id: } hashes. Empty if only one guide.
    def discover_order_guides
      guides = browser.evaluate(<<~JS)
        (function() {
          var results = [];
          // Look for dropdown or select near "Order Guide" heading
          var heading = null;
          var headings = document.querySelectorAll('h1, h2, h3, [class*="heading"], [class*="title"]');
          for (var i = 0; i < headings.length; i++) {
            if ((headings[i].innerText || '').toLowerCase().includes('order guide')) {
              heading = headings[i];
              break;
            }
          }
          if (!heading) return results;

          // Look for a dropdown trigger (chevron/arrow) near the heading
          var dropdown = heading.querySelector('svg, [class*="arrow"], [class*="chevron"], [class*="dropdown"]') ||
                         heading.parentElement?.querySelector('[class*="dropdown"], select');
          if (dropdown) {
            // Click to open dropdown
            dropdown.click && dropdown.click();
          }

          // Wait briefly, then look for dropdown options
          var options = document.querySelectorAll('[class*="dropdown"] li, [class*="menu"] li, [role="option"], [role="menuitem"]');
          for (var j = 0; j < options.length; j++) {
            var text = (options[j].innerText || '').trim();
            if (text.length > 0 && text.length < 100) {
              results.push({
                name: text,
                remote_id: text.toLowerCase().replace(/[^a-z0-9]+/g, '-')
              });
            }
          }

          return results;
        })()
      JS

      (guides || []).map { |g| { name: g['name'], remote_id: g['remote_id'] } }
    rescue StandardError
      []
    end

    # Select a specific order guide from the dropdown.
    def select_order_guide(guide_name)
      browser.evaluate(<<~JS)
        (function() {
          // Click dropdown to open
          var headings = document.querySelectorAll('h1, h2, h3, [class*="heading"], [class*="title"]');
          for (var i = 0; i < headings.length; i++) {
            if ((headings[i].innerText || '').toLowerCase().includes('order guide')) {
              var trigger = headings[i].querySelector('svg, [class*="arrow"], [class*="chevron"]') || headings[i];
              trigger.click && trigger.click();
              break;
            }
          }

          // Find and click the matching option
          setTimeout(function() {
            var options = document.querySelectorAll('[class*="dropdown"] li, [class*="menu"] li, [role="option"], [role="menuitem"]');
            for (var j = 0; j < options.length; j++) {
              if ((options[j].innerText || '').trim() === '#{guide_name.gsub("'", "\\\\'")}') {
                options[j].click();
                return true;
              }
            }
          }, 500);
        })()
      JS
      sleep 2
    rescue StandardError => e
      logger.warn "[PremiereProduceOne] Could not select guide '#{guide_name}': #{e.message}"
    end

    # Extract products from the current Order Guide page.
    # Uses the same text-parsing approach as extract_products_from_catalog
    # but returns items in the list item format.
    def extract_order_guide_products_ppo
      # Make sure "All" category filter is selected
      all_clicked = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('button');
          for (var i = 0; i < buttons.length; i++) {
            var text = buttons[i].innerText.trim();
            if (text === 'All') {
              buttons[i].click();
              return 'clicked All button';
            }
          }
          // Log what category buttons we can see
          var cats = [];
          for (var i = 0; i < buttons.length; i++) {
            var text = buttons[i].innerText.trim();
            if (text.length > 0 && text.length < 20) cats.push(text);
          }
          return 'no All button found, buttons: ' + cats.slice(0, 10).join(', ');
        })()
      JS
      logger.info "[PremiereProduceOne] Category filter: #{all_clicked}"
      sleep 3
      wait_for_react_render(timeout: 10)

      # Diagnose the page structure — find ALL scrollable elements
      scroll_info = browser.evaluate(<<~JS) rescue {}
        (function() {
          var info = {
            bodyScroll: document.body.scrollHeight + 'x' + document.body.clientHeight,
            docScroll: document.documentElement.scrollHeight + 'x' + document.documentElement.clientHeight,
            scrollables: []
          };

          // Find ALL elements with overflow scroll/auto that are actually scrollable
          var all = document.querySelectorAll('*');
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            var style = window.getComputedStyle(el);
            var overY = style.overflowY;
            if ((overY === 'auto' || overY === 'scroll') && el.scrollHeight > el.clientHeight + 10) {
              info.scrollables.push({
                tag: el.tagName,
                classes: el.className.toString().substring(0, 80),
                id: el.id || '',
                scrollHeight: el.scrollHeight,
                clientHeight: el.clientHeight,
                scrollTop: el.scrollTop,
                overflowY: overY,
                childCount: el.children.length
              });
            }
          }

          // Also check window scroll
          info.windowScrollY = window.scrollY;
          info.windowInnerHeight = window.innerHeight;

          return info;
        })()
      JS
      logger.info "[PremiereProduceOne] Page scroll diagnostics: body=#{scroll_info['bodyScroll']}, doc=#{scroll_info['docScroll']}, window=#{scroll_info['windowScrollY']}/#{scroll_info['windowInnerHeight']}"
      (scroll_info['scrollables'] || []).each_with_index do |s, idx|
        logger.info "[PremiereProduceOne] Scrollable ##{idx}: <#{s['tag']}> class=#{s['classes'][0..60]} scrollH=#{s['scrollHeight']} clientH=#{s['clientHeight']} scrollTop=#{s['scrollTop']} children=#{s['childCount']}"
      end

      # Pick the best scrollable container — prefer the one with the most scrollable content
      # that is not the HTML or BODY element (those are handled by window.scrollBy)
      browser.evaluate(<<~JS)
        window.__ppoScrollContainer = (function() {
          var best = null;
          var bestRatio = 0;
          var all = document.querySelectorAll('*');
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            if (el === document.body || el === document.documentElement) continue;
            var style = window.getComputedStyle(el);
            var overY = style.overflowY;
            if ((overY === 'auto' || overY === 'scroll') && el.scrollHeight > el.clientHeight + 50) {
              var ratio = el.scrollHeight / el.clientHeight;
              if (ratio > bestRatio) {
                bestRatio = ratio;
                best = el;
              }
            }
          }
          if (best) {
            window.__ppoScrollInfo = best.tagName + '.' + (best.className || '').toString().substring(0, 50) + ' ratio=' + bestRatio.toFixed(1);
          }
          return best;
        })();
      JS
      container_info = browser.evaluate('window.__ppoScrollInfo || "none — using window scroll"') rescue 'unknown'
      logger.info "[PremiereProduceOne] Scroll container: #{container_info}"

      # Discover what unit types exist on the page before scrolling
      # PPO is a produce supplier — units go well beyond Case/Each/Piece
      unit_sample = browser.evaluate(<<~JS) rescue []
        (function() {
          var text = document.body.innerText;
          // Match any word(s) before • or · followed by a 3+ digit SKU
          var matches = text.match(/\\b[A-Za-z][A-Za-z ]{0,15}\\s*[•·]\\s*\\d{3,}/g) || [];
          // Extract just the unit parts
          var units = {};
          for (var i = 0; i < matches.length; i++) {
            var unit = matches[i].replace(/\\s*[•·]\\s*\\d+.*/, '').trim();
            units[unit] = (units[unit] || 0) + 1;
          }
          return units;
        })()
      JS
      logger.info "[PremiereProduceOne] Unit types found on page: #{unit_sample.inspect}"

      # PPO uses VIRTUAL SCROLLING — only ~54 items are in the DOM at any time.
      # We must extract products at each scroll position and accumulate by SKU.
      # Scrolling swaps items in/out of the DOM, so document.body.innerText
      # always shows roughly the same count (~54) regardless of position.
      all_products = {}  # SKU → product hash (deduplicates across scroll positions)
      max_scrolls = 50
      stale_rounds = 0

      max_scrolls.times do |attempt|
        prev_size = all_products.size

        # Extract products visible at current scroll position
        extract_visible_products(all_products)

        new_items = all_products.size - prev_size

        # Check scroll position — stop when we've reached the bottom
        scroll_state = browser.evaluate(<<~JS) rescue {}
          (function() {
            var c = window.__ppoScrollContainer;
            if (c) return { top: c.scrollTop, height: c.scrollHeight, client: c.clientHeight };
            return { top: window.scrollY, height: document.body.scrollHeight, client: window.innerHeight };
          })()
        JS

        at_bottom = (scroll_state['top'].to_i + scroll_state['client'].to_i) >= (scroll_state['height'].to_i - 50)

        if attempt < 5 || (attempt + 1) % 5 == 0 || new_items > 0 || at_bottom
          logger.info "[PremiereProduceOne] Scroll #{attempt + 1}: #{all_products.size} unique items (+#{new_items} new) scrollTop=#{scroll_state['top']}/#{scroll_state['height']}"
        end

        break if at_bottom

        # Check for stale — if extraction found no new items
        if new_items == 0 && attempt > 0
          stale_rounds += 1
          break if stale_rounds >= 10  # generous for virtual scroll
        else
          stale_rounds = 0
        end

        # Scroll down
        browser.evaluate(<<~JS)
          (function() {
            var container = window.__ppoScrollContainer;
            if (container) {
              container.scrollTop += container.clientHeight * 0.8;
              container.dispatchEvent(new Event('scroll', { bubbles: true }));
            } else {
              window.scrollBy(0, window.innerHeight * 0.8);
            }
          })();
        JS
        sleep 2
      end

      logger.info "[PremiereProduceOne] Scrolling complete: #{all_products.size} unique items collected"

      # Log unit breakdown
      unit_counts = all_products.values.group_by { |p| p[:pack_size].to_s.split(' - ').first }.transform_values(&:count)
      logger.info "[PremiereProduceOne] Final unit breakdown: #{unit_counts.inspect}"

      # Assign final positions
      products = all_products.values.each_with_index.map do |prod, idx|
        prod[:position] = idx + 1
        prod
      end

      products
    end

    # Extract products from the currently visible viewport and merge into the accumulator.
    # Called repeatedly during virtual-scroll traversal. Deduplicates by SKU.
    def extract_visible_products(accumulator)
      page_text = begin
        browser.evaluate("document.body ? document.body.innerText : ''")
      rescue StandardError
        ''
      end

      lines = page_text.split("\n").map(&:strip).reject(&:blank?)

      lines.each_with_index do |line, i|
        # Match any unit type followed by • or · and a 3+ digit SKU
        sku_match = line.match(/^([A-Za-z][A-Za-z ]{0,15}?)\s*[•·]\s*(\d{3,})$/)
        next unless sku_match

        unit = sku_match[1].strip
        sku = sku_match[2]

        # Skip if we already have this SKU
        next if accumulator.key?(sku)

        name = nil
        price = nil
        pack_size = nil
        brand = nil

        # Walk backwards to find product details
        (i - 1).downto([i - 6, 0].max) do |j|
          prev_line = lines[j]
          next if prev_line.match?(/^(All|BAKERY|BEVERAGE|DAIRY|FFV|FOODSERVICE|PANTRY|PRODUCE|PROTEIN|SPECIALTY|Sort:)/)
          next if prev_line.match?(/^\d+\s+fulfilled\s+on\s+/i)
          next if prev_line.match?(/^Add to cart$/i)
          next if prev_line.match?(/^\d+\s*[-+]$/)
          next if prev_line.match?(/^See all \d+ products/)

          if prev_line.include?('Brand:') || prev_line.include?('Pack Size:')
            brand_match = prev_line.match(/Brand:\s*([^|]+)/)
            brand = brand_match[1].strip if brand_match
            pack_match = prev_line.match(/Pack Size:\s*([^|]+)/)
            pack_size = pack_match[1].strip if pack_match
            price_match = prev_line.match(/\$([\d,.]+)/)
            price = price_match[1].gsub(',', '').to_f if price_match
            next
          end

          if !price && /^\$[\d,.]+$/.match?(prev_line)
            price = prev_line.gsub(/[$,]/, '').to_f
            next
          end

          unless price
            p_match = prev_line.match(/\$([\d,.]+)/)
            if p_match && prev_line.length < 30
              price = p_match[1].gsub(',', '').to_f
              next
            end
          end

          next unless !name && prev_line.length > 2 && prev_line.length < 120 && !prev_line.include?('|') &&
                      !/^[a-z]/.match?(prev_line) && !/fulfilled on/i.match?(prev_line) &&
                      !/^\d+\s+(fulfilled|ordered|delivered)/i.match?(prev_line)

          name = prev_line
          break
        end

        next unless name && sku
        next if /^\d+\s+fulfilled/i.match?(name) || /fulfilled on/i.match?(name)

        # Look forward for price if not found above
        unless price
          ((i + 1)..[i + 3, lines.length - 1].min).each do |k|
            fwd_line = lines[k]
            if /^\$[\d,.]+$/.match?(fwd_line)
              price = fwd_line.gsub(/[$,]/, '').to_f
              break
            end
            fwd_match = fwd_line.match(/^\$([\d,.]+)/)
            if fwd_match
              price = fwd_match[1].gsub(',', '').to_f
              break
            end
            break if /^Add note$/i.match?(fwd_line) || /^[A-Za-z]+\s*[•·]\s*\d{3,}/.match?(fwd_line)
          end
        end

        full_name = brand.present? ? "#{name} #{brand}".truncate(255) : name.truncate(255)

        accumulator[sku] = {
          sku: sku,
          name: full_name,
          price: price,
          pack_size: pack_size.present? ? "#{unit} - #{pack_size}" : unit,
          quantity: 1,
          in_stock: true,
          position: 0  # assigned later
        }
      end
    end

    # Browse a category by clicking on the category filter/sidebar
    # PPO uses a sidebar with category buttons/filters
    def browse_category(category_slug, max: 50)
      ensure_catalog_page_loaded

      # Try to find and click the category filter
      # PPO categories are typically shown as buttons or links in the sidebar
      category_clicked = begin
        browser.evaluate(<<~JS)
          (function() {
            var targetCategory = '#{category_slug}';

            // Look for category buttons/links by text or data attribute
            var elements = document.querySelectorAll('button, a, [role="button"]');
            for (var el of elements) {
              var text = (el.innerText || '').toLowerCase();
              var ariaLabel = (el.getAttribute('aria-label') || '').toLowerCase();

              // Match by category name (case insensitive)
              if (text.includes(targetCategory) || ariaLabel.includes(targetCategory)) {
                el.click();
                return true;
              }
            }

            // Try to find category in any clickable element
            var allClickable = document.querySelectorAll('[class*="category"], [class*="filter"]');
            for (var el of allClickable) {
              if (el.innerText.toLowerCase().includes(targetCategory)) {
                el.click();
                return true;
              }
            }

            return false;
          })()
        JS
      rescue StandardError
        false
      end

      if category_clicked
        logger.info "[PremiereProduceOne] Clicked category: #{category_slug}"
        sleep 3 # Wait for React to filter products
      else
        logger.debug "[PremiereProduceOne] Could not click category '#{category_slug}', using search fallback"
        # Fallback: search for the category name as a term
        search_input = browser.at_css("input[placeholder='Search']")
        if search_input
          search_input.focus
          set_react_input_value(search_input, category_slug.to_s.titleize)
          sleep 2
        end
      end

      # Extract products from the filtered view
      extract_products_from_catalog(max)
    end

    # Extract products from the current catalog view
    # Shared method used by both browse_category and search_supplier_catalog
    def extract_products_from_catalog(max = 50)
      # Use the existing search result parsing logic
      page_text = begin
        browser.evaluate("document.body ? document.body.innerText : ''")
      rescue StandardError
        ''
      end

      # Parse products from the page text
      products = []
      lines = page_text.split("\n").map(&:strip).reject(&:blank?)

      lines.each_with_index do |line, i|
        # Look for "Case • NNNNN" pattern which marks the end of a product block
        sku_match = line.match(/^(?:Case|Each|Piece)\s*[•·]\s*(\d{3,})$/)
        next unless sku_match

        sku = sku_match[1]

        # Walk backwards to find the product name
        name = nil
        description = nil
        price = nil
        pack_size = nil
        brand = nil
        unit = line.match(/^(Case|Each|Piece)/)[1]

        # Look backwards for product details
        (i - 1).downto([i - 6, 0].max) do |j|
          prev_line = lines[j]

          # Skip category headers and irrelevant lines
          if prev_line.match?(/^(All|BAKERY|BEVERAGE|DAIRY|FFV|FOODSERVICE|PANTRY|PRODUCE|PROTEIN|SPECIALTY|Sort:)/)
            next
          end
          next if prev_line.match?(/^See all \d+ products/)
          next if prev_line.match?(/^\d+$/)
          next if prev_line.match?(/^".*"$/)
          next if prev_line.match?(/^\d+\s+fulfilled\s+on\s+/i)
          next if prev_line.match?(/^Add to cart$/i)
          next if prev_line.match?(/^\d+\s*[-+]$/)

          # Description line with Brand/Pack Size
          if prev_line.include?('Brand:') || prev_line.include?('Pack Size:')
            description = prev_line
            brand_match = prev_line.match(/Brand:\s*([^|]+)/)
            brand = brand_match[1].strip if brand_match
            pack_match = prev_line.match(/Pack Size:\s*([^|]+)/)
            pack_size = pack_match[1].strip if pack_match
            # Price might be on this same line
            price_match = prev_line.match(/\$([\d,.]+)/)
            price = price_match[1].gsub(',', '').to_f if price_match
            next
          end

          # Standalone price line
          if !price && /^\$[\d,.]+$/.match?(prev_line)
            price = prev_line.gsub(/[$,]/, '').to_f
            next
          end

          # Price with label
          unless price
            p_match = prev_line.match(/\$([\d,.]+)/)
            if p_match && prev_line.length < 30
              price = p_match[1].gsub(',', '').to_f
              next
            end
          end

          # Product name — typically ALL CAPS or mixed case
          next unless !name && prev_line.length > 2 && prev_line.length < 120 && !prev_line.include?('|') &&
                      !prev_line.start_with?('Storage') && !prev_line.start_with?('An ') &&
                      !prev_line.start_with?('A ') && !prev_line.start_with?('The ') &&
                      !prev_line.start_with?('Tender ') && !prev_line.start_with?('Made ') &&
                      !prev_line.start_with?('Pre-Order') && !prev_line.start_with?('Variable') &&
                      !/^[a-z]/.match?(prev_line) && !/fulfilled on/i.match?(prev_line) &&
                      !/^\d+\s+(fulfilled|ordered|delivered)/i.match?(prev_line)

          name = prev_line
          break
        end

        # Skip if no valid name found
        next unless name && sku
        next if /^\d+\s+fulfilled/i.match?(name) || /fulfilled on/i.match?(name)

        # Look forward for price if not found yet
        unless price
          ((i + 1)..[i + 3, lines.length - 1].min).each do |k|
            fwd_line = lines[k]
            if /^\$[\d,.]+$/.match?(fwd_line)
              price = fwd_line.gsub(/[$,]/, '').to_f
              break
            end
            fwd_match = fwd_line.match(/^\$([\d,.]+)/)
            if fwd_match
              price = fwd_match[1].gsub(',', '').to_f
              break
            end
            break if /^Add note$/i.match?(fwd_line) || /^(?:Case|Each|Piece)\s*[•·]/.match?(fwd_line)
          end
        end

        products << {
          supplier_sku: sku,
          supplier_name: brand.present? ? "#{name} #{brand}".truncate(255) : name.truncate(255),
          current_price: price,
          pack_size: pack_size.present? ? "#{unit} - #{pack_size}" : unit,
          supplier_url: "#{BASE_URL}/products/#{sku}",
          in_stock: !(description || '').include?('Special Order Item'),
          category: nil,
          scraped_at: Time.current
        }

        break if products.length >= max
      end

      products
    end

    # PPO is a React SPA (Pepper platform) with no semantic CSS classes.
    # Products are displayed as text blocks. The search input filters in-place.
    # We type into the search input, wait for results, then parse the text.
    #
    # PPO (Pepper React SPA) renders products as card-like divs. Each product
    # card's innerText looks like one of:
    #
    #   PRODUCT NAME
    #   Brand: BRAND | Pack Size: SIZE | ...
    #   Case • SKU
    #
    # Prices are NOT rendered in innerText — they're in a separate React
    # component. We first do a DOM probe to discover the price selector,
    # then fall back to text-only if prices aren't in the DOM either.
    #
    # Order history entries ("N fulfilled on DATE") also match the SKU
    # pattern, so we must filter those out.
    def search_supplier_catalog(term, max: 50)
      # Find and use the in-page search input
      search_input = browser.at_css("input[placeholder='Search']")
      unless search_input
        logger.warn '[PremiereProduceOne] Search input not found'
        return []
      end

      # Clear and type the search term
      search_input.focus
      sleep 0.3
      set_react_input_value(search_input, term)
      sleep 1.5 # Wait for React to filter results

      # DOM probe: scan all elements by innerText (not textContent) to handle
      # React's split-text-node rendering. Also search globally for $ prices.
      dom_probe = begin
        browser.evaluate(<<~JS)
          (function() {
            var url = window.location.href;

            // Find elements whose innerText matches SKU pattern
            var allEls = document.querySelectorAll("*");
            var skuEl = null;
            for (var i = 0; i < allEls.length; i++) {
              var el = allEls[i];
              if (el.children.length > 3) continue;
              var t = (el.innerText || "").trim();
              if (/^(?:Case|Each|Piece)\\s*[•·]\\s*\\d{3,}$/.test(t)) {
                skuEl = el;
                break;
              }
            }

            // Search for ANY dollar amounts anywhere on the page (leaf nodes)
            var dollarElements = [];
            for (var i = 0; i < allEls.length; i++) {
              var el = allEls[i];
              if (el.children.length > 0) continue;
              var t = (el.textContent || "").trim();
              if (/^\\$[\\d,.]+$/.test(t) && dollarElements.length < 15) {
                dollarElements.push({
                  text: t,
                  tag: el.tagName,
                  classes: (el.className || "").substring(0, 80),
                  parentClasses: el.parentElement ? (el.parentElement.className || "").substring(0, 80) : ""
                });
              }
            }

            // Also search for $ in innerText of elements (price might span nodes)
            var dollarInnerText = [];
            for (var i = 0; i < allEls.length; i++) {
              var el = allEls[i];
              if (el.children.length > 2) continue;
              var t = (el.innerText || "").trim();
              if (/^\\$[\\d,.]+$/.test(t) && dollarInnerText.length < 10) {
                dollarInnerText.push({text: t, tag: el.tagName, classes: (el.className || "").substring(0, 80)});
              }
            }

            if (!skuEl) {
              return JSON.stringify({found: false, url: url, dollarElements: dollarElements, dollarInnerText: dollarInnerText});
            }

            // Walk up from SKU, find product card
            var ancestors = [];
            var productCard = skuEl;
            var card = skuEl.parentElement;
            for (var i = 0; i < 10 && card && card !== document.body; i++) {
              var ct = card.innerText || "";
              ancestors.push({
                level: i, tag: card.tagName,
                classes: (card.className || "").substring(0, 120),
                textLen: ct.length, hasDollar: /\\$\\d/.test(ct), hasBrand: /Brand:/.test(ct)
              });
              if (ct.length > 50 && /Brand:|Pack Size:/.test(ct)) { productCard = card; break; }
              card = card.parentElement;
            }

            return JSON.stringify({
              found: true, url: url,
              ancestors: ancestors,
              cardText: (productCard.innerText || "").substring(0, 1500),
              cardHtml: productCard.outerHTML.substring(0, 4000),
              dollarElements: dollarElements,
              dollarInnerText: dollarInnerText
            });
          })()
        JS
      rescue StandardError
        nil
      end

      if dom_probe
        probe = begin
          JSON.parse(dom_probe)
        rescue StandardError
          {}
        end
        logger.info "[PremiereProduceOne] DOM probe URL: #{probe['url']}"
        logger.info "[PremiereProduceOne] DOM probe $ leaf nodes: #{probe['dollarElements']&.inspect}"
        logger.info "[PremiereProduceOne] DOM probe $ innerText: #{probe['dollarInnerText']&.inspect}"
        if probe['found']
          logger.info "[PremiereProduceOne] DOM probe SKU found! ancestors: #{probe['ancestors']&.map do |a|
            "#{a['tag']}(#{a['textLen']}ch,$=#{a['hasDollar']})"
          end&.join(' > ')}"
          logger.info "[PremiereProduceOne] DOM probe card text: #{probe['cardText']&.gsub("\n", ' | ')&.truncate(500)}"
          html = probe['cardHtml'] || ''
          if html.include?('$')
            price_html = html.scan(/.{0,80}\$[\d,.]+.{0,40}/)
            logger.info "[PremiereProduceOne] DOM probe price HTML: #{price_html.first(3).inspect}"
          else
            logger.info '[PremiereProduceOne] DOM probe: NO $ in card HTML'
          end
        else
          logger.warn '[PremiereProduceOne] DOM probe: no SKU element found via innerText scan'
        end
      end

      # Extract products from the page text using JavaScript
      products_json = browser.evaluate(<<~JS)
        (function() {
          var text = document.body.innerText;
          var lines = text.split("\\n").map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });
          var products = [];
          var debugLines = [];

          for (var i = 0; i < lines.length; i++) {
            // Look for "Case • NNNNN" pattern which marks the end of a product block
            var skuMatch = lines[i].match(/^(?:Case|Each|Piece)\\s*[•·]\\s*(\\d{3,})$/);
            if (!skuMatch) continue;

            var sku = skuMatch[1];

            // Walk backwards to find the product name, description, and price
            var name = null;
            var description = null;
            var price = null;
            var packSize = null;
            var brand = null;
            var unit = lines[i].match(/^(Case|Each|Piece)/)[1];
            var blockLines = [];

            for (var j = i - 1; j >= Math.max(0, i - 6); j--) {
              var line = lines[j];

              // Skip category headers (they're in the sidebar)
              if (/^(All|BAKERY|BEVERAGE|DAIRY|FFV|FOODSERVICE|PANTRY|PRODUCE|PROTEIN|SPECIALTY|Sort:)/.test(line)) continue;
              if (/^See all \\d+ products/.test(line)) continue;
              if (/^\\d+$/.test(line)) continue; // category counts
              if (/^".*"$/.test(line)) continue; // search term echo
              // Skip order history lines (e.g. "1 fulfilled on Oct 27, 2025")
              if (/^\\d+\\s+fulfilled\\s+on\\s+/i.test(line)) continue;
              // Skip "Add to cart" / quantity buttons
              if (/^Add to cart$/i.test(line) || /^\\d+\\s*[-+]$/.test(line)) continue;

              blockLines.unshift(line);

              // Description line with Brand/Pack Size
              if (line.includes("Brand:") || line.includes("Pack Size:")) {
                description = line;
                var brandMatch = line.match(/Brand:\\s*([^|]+)/);
                if (brandMatch) brand = brandMatch[1].trim();
                var packMatch = line.match(/Pack Size:\\s*([^|]+)/);
                if (packMatch) packSize = packMatch[1].trim();
                // Price might be on this same line
                var priceMatch = line.match(/\\$([\\d,.]+)/);
                if (priceMatch) price = parseFloat(priceMatch[1].replace(",", ""));
                continue;
              }

              // Standalone price line (e.g. "$5.99" or "$12.50")
              if (!price && /^\\$[\\d,.]+$/.test(line)) {
                price = parseFloat(line.replace("$", "").replace(",", ""));
                continue;
              }

              // Price with label (e.g. "Price: $5.99" or "$5.99 / case")
              if (!price) {
                var pMatch = line.match(/\\$([\\d,.]+)/);
                if (pMatch && line.length < 30) {
                  price = parseFloat(pMatch[1].replace(",", ""));
                  continue;
                }
              }

              // Product name — typically ALL CAPS or mixed case, before the description.
              // Skip lines that look like order history or fulfillment info.
              if (!name && line.length > 2 && line.length < 120 && !line.includes("|")
                  && !line.startsWith("Storage") && !line.startsWith("An ")
                  && !line.startsWith("A ") && !line.startsWith("The ")
                  && !line.startsWith("Tender ") && !line.startsWith("Made ")
                  && !line.startsWith("Pre-Order") && !line.startsWith("Variable")
                  && !/^[a-z]/.test(line)
                  && !/fulfilled on/i.test(line)
                  && !/^\\d+\\s+(fulfilled|ordered|delivered)/i.test(line)) {
                name = line;
                break;
              }
            }

            // Skip if no valid name found (likely order history entry)
            if (!name || !sku) continue;
            // Skip order history entries that slipped through
            if (/^\\d+\\s+fulfilled/i.test(name) || /fulfilled on/i.test(name)) continue;

            // PPO renders price AFTER the SKU line in the card text:
            //   ... | Case • SKU | $37.00 | Add note
            // Look forward from the SKU line for the price.
            if (!price) {
              for (var fwd = i + 1; fwd <= Math.min(i + 3, lines.length - 1); fwd++) {
                var fwdLine = lines[fwd];
                // Standalone price: "$37.00"
                if (/^\\$[\\d,.]+$/.test(fwdLine)) {
                  price = parseFloat(fwdLine.replace("$", "").replace(",", ""));
                  break;
                }
                // Price with unit: "$83.00   $8.30/pound"
                var fwdMatch = fwdLine.match(/^\\$([\\d,.]+)/);
                if (fwdMatch) {
                  price = parseFloat(fwdMatch[1].replace(",", ""));
                  break;
                }
                // Stop if we hit "Add note", another product, or a non-price line
                if (/^Add note$/i.test(fwdLine) || /^(?:Case|Each|Piece)\\s*[•·]/.test(fwdLine)) break;
              }
            }

            products.push({
              sku: sku,
              name: name,
              price: price,
              pack_size: packSize ? (unit + " - " + packSize) : unit,
              brand: brand,
              in_stock: !(description || "").includes("Special Order Item")
            });

            // Capture first few product blocks for debugging
            if (debugLines.length < 3) {
              debugLines.push({sku: sku, name: name, price: price, lines: blockLines});
            }

            if (products.length >= #{max}) break;
          }

          return JSON.stringify({products: products, debug: debugLines});
        })()
      JS

      parsed = begin
        JSON.parse(products_json)
      rescue StandardError
        {}
      end
      items = parsed['products'] || []
      debug = parsed['debug'] || []

      items_with_price = items.count { |i| i['price'].present? }
      logger.info "[PremiereProduceOne] Parsed #{items.size} products for '#{term}' (#{items_with_price} with prices)"
      debug.each do |d|
        logger.info "[PremiereProduceOne] DEBUG product: sku=#{d['sku']} name=#{d['name']} price=#{d['price']} lines=#{d['lines'].inspect}"
      end

      items.map do |item|
        {
          supplier_sku: item['sku'],
          supplier_name: item['name'].to_s.truncate(255),
          current_price: item['price'],
          pack_size: item['pack_size'],
          supplier_url: "#{BASE_URL}/products/#{item['sku']}",
          in_stock: item['in_stock'] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    rescue StandardError => e
      logger.warn "[PremiereProduceOne] search_supplier_catalog error for '#{term}': #{e.message}"
      []
    end

    def scrape_product(sku)
      navigate_to("#{BASE_URL}/products/#{sku}")

      return nil unless browser.at_css('.product-page, .product-detail')

      {
        supplier_sku: sku,
        supplier_name: extract_text('.product-title, .product-name, h1'),
        current_price: extract_price(extract_text('.price, .product-price, .current-price')),
        pack_size: extract_text('.pack-size, .product-unit'),
        in_stock: browser.at_css('.out-of-stock, .unavailable, .sold-out').nil?,
        scraped_at: Time.current
      }
    end

    def detect_unavailable_items_in_cart
      unavailable = []

      browser.css('.cart-item, .cart-product').each do |item|
        next unless item.at_css('.out-of-stock, .not-available')

        unavailable << {
          sku: item.at_css('[data-sku], [data-product]')&.attribute('data-sku'),
          name: item.at_css('.item-name, .product-title')&.text&.strip,
          message: item.at_css('.availability-msg')&.text&.strip
        }
      end

      unavailable
    end

    def validate_cart_before_checkout
      detect_error_conditions

      return unless browser.at_css('.empty-cart, .cart-empty, .no-items')

      raise ScrapingError, 'Cart is empty'
    end

    def wait_for_confirmation_or_error
      start_time = Time.current
      timeout = 30

      loop do
        return true if browser.at_css('.order-confirmation, .success, .thank-you-page')

        error_msg = browser.at_css('.error-message, .checkout-error, .alert-danger')&.text&.strip
        raise ScrapingError, "Checkout failed: #{error_msg}" if error_msg

        raise ScrapingError, 'Checkout timeout' if Time.current - start_time > timeout

        sleep 0.5
      end
    end

    def two_fa_page?
      return true if browser.at_css("input[placeholder='Code']")

      body_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 3000)')
      rescue StandardError
        ''
      end
      return true if body_text.include?('Verification code')
      return true if body_text.match?(/code.*been sent|enter.*code|verification.*code/i)
      return true if body_text.match?(/we.?(?:sent|texted|emailed).*code/i)
      return true if body_text.match?(/check your (?:phone|email|text)/i)

      code_selectors = [
        "input[name*='code']",
        "input[name*='verification']",
        "input[name*='otp']",
        "input[autocomplete='one-time-code']",
        '.verification-code-input',
        '.otp-input'
      ]

      code_selectors.each do |selector|
        return true if browser.at_css(selector)
      end

      false
    end

    def find_2fa_code_input
      el = browser.at_css("input[placeholder='Code']")
      return el if el

      specific_selectors = [
        "input[name*='code']",
        "input[name*='verification']",
        "input[name*='otp']",
        "input[autocomplete='one-time-code']",
        '.verification-code-input input',
        '.otp-input input',
        '#verificationCode'
      ]

      specific_selectors.each do |selector|
        el = browser.at_css(selector)
        return el if el
      end

      browser.css("input[type='text'], input[type='tel'], input[type='number']").each do |input|
        placeholder = begin
          input.evaluate("this.placeholder || ''")
        rescue StandardError
          ''
        end
        next if placeholder.match?(/email|password|search|phone/i)
        return input if placeholder.match?(/code|otp|verify|token/i)
      end

      browser.at_css("input[type='text']")
    end

    # Click a button by its visible text (case-insensitive exact match).
    # Clicks the FIRST matching button.
    def click_button_by_text(text)
      js = "(function() { var btns = document.querySelectorAll('button, [role=\"button\"]'); for (var i = 0; i < btns.length; i++) { if (btns[i].innerText.trim().toLowerCase() === '#{text.downcase}') { btns[i].click(); return true; } } return false; })()"
      result = begin
        browser.evaluate(js)
      rescue StandardError
        false
      end
      logger.debug "[PremiereProduceOne] Button '#{text}' not found" unless result
      result
    end

    # Click the LAST button matching the given text.
    # Useful in React SPAs where previous views may still be in the DOM.
    def click_last_button_by_text(text)
      js = "(function() { var btns = document.querySelectorAll('button, [role=\"button\"]'); var last = null; for (var i = 0; i < btns.length; i++) { if (btns[i].innerText.trim().toLowerCase() === '#{text.downcase}') { last = btns[i]; } } if (last) { last.click(); return true; } return false; })()"
      result = begin
        browser.evaluate(js)
      rescue StandardError
        false
      end
      logger.debug "[PremiereProduceOne] Button '#{text}' (last) not found" unless result
      result
    end

    def save_trusted_device
      remember_selectors = [
        "input[name*='remember']",
        "input[name*='trust']",
        '#rememberDevice',
        ".trust-device input[type='checkbox']",
        "input[name*='dont_ask']",
        "label[for*='remember'] input",
        "label[for*='trust'] input"
      ]

      remember_selectors.each do |selector|
        checkbox = browser.at_css(selector)
        next unless checkbox

        begin
          checked = begin
            checkbox.evaluate('this.checked')
          rescue StandardError
            false
          end
          unless checked
            checkbox.evaluate('this.click()')
            logger.info "[PremiereProduceOne] Checked 'remember device' checkbox"
          end
        rescue StandardError => e
          logger.debug "[PremiereProduceOne] Could not check remember device: #{e.message}"
        end
        break
      end

      button_selectors = [
        "button[class*='trust']",
        "button[class*='remember']",
        "a[class*='trust']",
        "[data-action*='trust']"
      ]

      button_selectors.each do |selector|
        btn = browser.at_css(selector)
        next unless btn

        begin
          btn.evaluate('this.click()')
          logger.info "[PremiereProduceOne] Clicked 'trust device' button"
        rescue StandardError => e
          logger.debug "[PremiereProduceOne] Could not click trust button: #{e.message}"
        end
        break
      end
    rescue StandardError => e
      logger.debug "[PremiereProduceOne] save_trusted_device error: #{e.message}"
    end

    # ─── Checkout helper methods ───────────────────────────────────

    def navigate_to_cart_page_ppo
      # Try /cart first (Pepper platform standard)
      navigate_to("#{BASE_URL}/cart")
      sleep 1.5
      wait_for_react_render(timeout: 5)

      page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''

      # If we're not on a cart-looking page, try clicking the cart icon
      unless page_text.match?(/cart|checkout|order|subtotal|\$\d+\.\d{2}/i)
        logger.info '[PremiereProduceOne] /cart did not show cart content, trying cart icon'
        browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('a[href*="cart"], button[class*="cart"], [aria-label*="cart" i], [aria-label*="Cart"]');
            for (var el of els) {
              if (el.offsetParent !== null) { el.click(); return true; }
            }
            var svgs = document.querySelectorAll('svg');
            for (var svg of svgs) {
              var parent = svg.closest('a, button');
              var ariaLabel = parent ? (parent.getAttribute('aria-label') || '').toLowerCase() : '';
              if (ariaLabel.includes('cart') || ariaLabel.includes('basket')) {
                parent.click();
                return true;
              }
            }
            return false;
          })()
        JS
        sleep 1.5
        wait_for_react_render(timeout: 5)
        page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
      end

      logger.info "[PremiereProduceOne] Cart page URL: #{browser.current_url rescue 'unknown'}"

      # Scroll to bottom to reveal sticky footer / submit button
      browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
      sleep 1

      # Enhanced DOM discovery for Pepper React Native Web:
      # - Use textContent (not innerText) because RN Web nests text in <div>s
      # - Log buttons at both top and bottom of page
      # - Check for fixed/sticky elements (footer with submit button)
      dom_info = browser.evaluate(<<~JS)
        (function() {
          var allButtons = Array.from(document.querySelectorAll('button, [role="button"]'))
            .filter(function(b) { return b.offsetParent !== null; });

          // Get buttons with non-empty textContent (these are actionable buttons)
          var namedButtons = allButtons
            .filter(function(b) {
              var tc = (b.textContent || '').trim();
              return tc.length > 0 && tc.length < 60;
            })
            .map(function(b) {
              var rect = b.getBoundingClientRect();
              return {
                text: (b.textContent || '').trim().substring(0, 60),
                innerText: (b.innerText || '').trim().substring(0, 40),
                classes: (b.className || '').substring(0, 60),
                aria: (b.getAttribute('aria-label') || '').substring(0, 40),
                has_svg: !!b.querySelector('svg'),
                y: Math.round(rect.top),
                fixed: window.getComputedStyle(b).position === 'fixed' ||
                       window.getComputedStyle(b.parentElement || b).position === 'fixed'
              };
            });

          // Find fixed/sticky positioned elements (likely footer with submit)
          var fixedEls = Array.from(document.querySelectorAll('*'))
            .filter(function(el) {
              var style = window.getComputedStyle(el);
              return (style.position === 'fixed' || style.position === 'sticky') &&
                     el.offsetParent !== null &&
                     el.getBoundingClientRect().bottom > window.innerHeight * 0.7;
            })
            .slice(0, 5)
            .map(function(el) {
              return {
                tag: el.tagName,
                text: (el.textContent || '').trim().substring(0, 200),
                classes: (el.className || '').substring(0, 80)
              };
            });

          // Page bottom text (last 500 chars of page)
          var fullText = document.body ? document.body.innerText : '';
          var bottomText = fullText.substring(Math.max(0, fullText.length - 500));

          return {
            url: window.location.href,
            title: document.title,
            total_buttons: allButtons.length,
            named_buttons: namedButtons,
            fixed_elements: fixedEls,
            bottom_text: bottomText,
            input_count: document.querySelectorAll('input').length
          };
        })()
      JS
      logger.info "[PremiereProduceOne] Cart DOM: #{(dom_info || {}).except('bottom_text').inspect}"
      logger.info "[PremiereProduceOne] Cart bottom text: #{dom_info&.dig('bottom_text')}"
      logger.info "[PremiereProduceOne] Fixed elements: #{dom_info&.dig('fixed_elements')&.inspect}"

      # Scroll back to top for cart extraction
      browser.evaluate('window.scrollTo(0, 0)')
      sleep 1
    end

    def extract_cart_data_ppo
      # First, open the View Order panel to see actual cart items
      # (the /cart page shows the order guide, NOT the shopping cart)
      view_order_btn = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('button, [role="button"]');
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
            if (aria.includes('view order')) {
              var rect = btn.getBoundingClientRect();
              return { found: true, x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
            }
          }
          return { found: false };
        })()
      JS

      if view_order_btn && view_order_btn['found']
        browser.mouse.click(x: view_order_btn['x'].to_f, y: view_order_btn['y'].to_f)
        sleep 2
        wait_for_react_render(timeout: 10)
        logger.info '[PremiereProduceOne] Opened View Order panel for cart data extraction'
      else
        logger.warn '[PremiereProduceOne] View Order button not found — extracting from full page (may include order guide items)'
      end

      cart_data = browser.evaluate(<<~JS)
        (function() {
          var result = { items: [], subtotal: 0, item_count: 0, unavailable: [] };

          // Scope to cart panel if one exists (avoid reading order guide items)
          var panel = null;

          // Strategy 1: role="dialog" or aria-modal
          var dialogs = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
          if (dialogs.length > 0) panel = dialogs[dialogs.length - 1];

          // Strategy 2: Find container with "Order Summary" heading (PPO's overlay)
          if (!panel) {
            var allEls = document.querySelectorAll('div, section, aside');
            for (var el of allEls) {
              var text = (el.textContent || '').substring(0, 500).toLowerCase();
              if (text.includes('order summary') && text.includes('estimated total') &&
                  el.getBoundingClientRect().width > 200) {
                // Make sure it's not the full body (should be smaller)
                if (el.getBoundingClientRect().width < window.innerWidth * 0.9) {
                  panel = el;
                  break;
                }
              }
            }
          }

          // Strategy 3: Container with "Place" + "order" button and "Estimated Total"
          if (!panel) {
            var allEls = document.querySelectorAll('div, section, aside');
            for (var el of allEls) {
              var text = (el.textContent || '').toLowerCase();
              if (/place.*order/i.test(text) && text.includes('estimated total') &&
                  el.getBoundingClientRect().width > 200 &&
                  el.getBoundingClientRect().width < window.innerWidth * 0.9) {
                panel = el;
                break;
              }
            }
          }

          // Strategy 4: Fixed/absolute positioned panel on right side
          if (!panel) {
            var allEls = document.querySelectorAll('div, section, aside');
            for (var el of allEls) {
              var style = window.getComputedStyle(el);
              if ((style.position === 'fixed' || style.position === 'absolute') &&
                  el.getBoundingClientRect().right > window.innerWidth * 0.5 &&
                  el.getBoundingClientRect().width > 200 &&
                  el.getBoundingClientRect().width < window.innerWidth * 0.8) {
                var text = (el.textContent || '').toLowerCase();
                if (/place.*order/i.test(text) || text.includes('view order') || text.includes('subtotal') || text.includes('estimated total')) {
                  panel = el;
                  break;
                }
              }
            }
          }

          var pageText = panel ? panel.innerText : (document.body ? document.body.innerText : '');
          result.scoped_to_panel = !!panel;

          // Subtotal: check for aria-label="View Order" button first (Pepper's cart total button)
          var viewOrderBtn = document.querySelector('[aria-label="View Order"]');
          if (viewOrderBtn) {
            var btnText = (viewOrderBtn.textContent || '').trim();
            var m = btnText.match(/\\$([\\d,]+\\.\\d{2})/);
            if (m) result.subtotal = parseFloat(m[1].replace(',', ''));
          }

          // Fallback subtotal from page text
          if (result.subtotal === 0) {
            var subtotalPatterns = [
              /subtotal[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
              /cart\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
              /total[:\\s]*\\$([\\d,]+\\.\\d{2})/i
            ];
            for (var p of subtotalPatterns) {
              var m = pageText.match(p);
              if (m) { result.subtotal = parseFloat(m[1].replace(',', '')); break; }
            }
          }

          // Pepper does NOT use standard <input> elements for quantities.
          // Parse cart items from page text instead.
          // PPO cart format per item:
          //   PRODUCT NAME
          //   Brand: X | Pack Size: Y
          //   Case • SKU
          //   $XX.XX
          //   Add note
          var lines = pageText.split('\\n').map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });
          var i = 0;
          while (i < lines.length) {
            var line = lines[i];
            // Look for "Case • NNNNN" or "Each • NNNNN" pattern (SKU line)
            var skuMatch = line.match(/^(?:Case|Each|Piece)\\s*[•·]\\s*(\\d{3,})$/);
            if (skuMatch) {
              var sku = skuMatch[1];
              // Name is 2-3 lines above the SKU line
              var name = '';
              for (var j = i - 1; j >= Math.max(0, i - 4); j--) {
                var candidate = lines[j];
                if (candidate.length > 3 && candidate.length < 100 &&
                    !candidate.match(/^Brand:/i) && !candidate.match(/^\\$/) &&
                    !candidate.match(/^\\d+ fulfilled/i) && !candidate.match(/^Add note/i) &&
                    !candidate.match(/^(?:Case|Each|Piece)\\s*[•·]/)) {
                  name = candidate;
                  break;
                }
              }

              // Price is on the line after SKU
              var price = 0;
              for (var k = i + 1; k < Math.min(lines.length, i + 3); k++) {
                var priceMatch = lines[k].match(/^\\$([\\d,]+\\.\\d{2})/);
                if (priceMatch) {
                  price = parseFloat(priceMatch[1].replace(',', ''));
                  break;
                }
              }

              var isUnavailable = false;
              // Check nearby lines for out of stock
              for (var m = Math.max(0, i - 2); m < Math.min(lines.length, i + 4); m++) {
                if (/out of stock|unavailable|discontinued/i.test(lines[m])) {
                  isUnavailable = true;
                  break;
                }
              }

              var item = { name: name.substring(0, 80), sku: sku, price: price, quantity: 1 };
              result.items.push(item);
              if (isUnavailable) result.unavailable.push(item);
            }
            i++;
          }

          result.item_count = result.items.length;

          // Calculate subtotal from items if the View Order button wasn't found
          if (result.subtotal === 0 && result.items.length > 0) {
            result.subtotal = result.items.reduce(function(s, it) { return s + it.price * it.quantity; }, 0);
          }

          // Last resort: largest $ amount on page
          if (result.subtotal === 0) {
            var amounts = (pageText.match(/\\$[\\d,]+\\.\\d{2}/g) || [])
              .map(function(p) { return parseFloat(p.replace(/[\\$,]/g, '')); });
            if (amounts.length > 0) result.subtotal = Math.max.apply(null, amounts);
          }

          return result;
        })()
      JS

      scoped = cart_data['scoped_to_panel'] ? 'cart panel' : 'full page (WARN: may include order guide)'
      logger.info "[PremiereProduceOne] Cart extraction (#{scoped}): items=#{(cart_data['items'] || []).size}, subtotal=#{cart_data['subtotal']}, item_count=#{cart_data['item_count']}"

      {
        items: (cart_data['items'] || []).map { |i| { name: i['name'], sku: i['sku'], price: i['price'], quantity: i['quantity'] } },
        subtotal: cart_data['subtotal'] || 0,
        item_count: [cart_data['item_count'] || 0, (cart_data['items'] || []).size].max,
        unavailable_items: (cart_data['unavailable'] || []).map { |i| { name: i['name'], sku: i['sku'], message: 'Unavailable' } }
      }
    end

    def proceed_to_checkout_page_ppo
      # Navigate to the checkout REVIEW page — DO NOT click order-finalizing buttons.
      # Pepper cart flow:
      # 1. /cart page shows items + a "View Order" button (shows as "$X.XX" with aria-label="View Order")
      # 2. Clicking "View Order" takes you to the order review/submit page
      # 3. Review page has "Submit Order" button — ONLY clicked by click_place_order_button_ppo AFTER dry run gate
      #
      # The "View Order" button is at the TOP of the page (sticky header at y=0).
      # It has aria-label="View Order" and textContent like "$1,396.20".

      # Step 1: Find the "View Order" button and get its coordinates
      # IMPORTANT: Do NOT use el.click() — it doesn't trigger React Native Web's
      # Pressable/Responder system. Instead, get coordinates and use CDP mouse.click.
      btn_info = browser.evaluate(<<~JS)
        (function() {
          var elements = document.querySelectorAll('button, [role="button"], a, div[class*="css-"]');

          // Priority 1: aria-label based detection (Pepper uses "View Order")
          var ariaTargets = ['view order', 'review order', 'checkout', 'view cart', 'order summary'];
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var aria = (el.getAttribute('aria-label') || '').toLowerCase();
            if (!aria) continue;
            for (var target of ariaTargets) {
              if (aria.includes(target)) {
                el.scrollIntoView({ behavior: 'instant', block: 'center' });
                var rect = el.getBoundingClientRect();
                return {
                  found: true,
                  text: (el.textContent || '').trim().substring(0, 60),
                  aria: aria,
                  method: 'aria-label',
                  x: rect.x + rect.width / 2,
                  y: rect.y + rect.height / 2
                };
              }
            }
          }

          // SAFETY: Order-finalizing text — never click these before dry run gate
          var orderFinalizing = /submit order|place order|complete order|^submit$/i;

          // Priority 2: textContent match for NAVIGATION buttons only
          var exclude = /search|clear|close|cancel|filter|back|sign|log|add note/i;
          var navTargets = ['checkout', 'proceed to checkout', 'review order', 'view order', 'continue to checkout'];
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var text = (el.textContent || '').trim().toLowerCase();
            if (text.length > 60 || text.length === 0) continue;
            if (exclude.test(text)) continue;
            if (orderFinalizing.test(text)) continue;
            for (var target of navTargets) {
              if (text.includes(target)) {
                el.scrollIntoView({ behavior: 'instant', block: 'center' });
                var rect = el.getBoundingClientRect();
                return { found: true, text: text, tag: el.tagName, method: 'textContent-match', x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
              }
            }
          }

          // Priority 3: Button containing $ amount with SVG (the cart total button)
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var text = (el.textContent || '').trim();
            var hasSvg = !!el.querySelector('svg');
            if (text.match(/^\\$[\\d,]+\\.\\d{2}$/) && hasSvg) {
              el.scrollIntoView({ behavior: 'instant', block: 'center' });
              var rect = el.getBoundingClientRect();
              return { found: true, text: text, method: 'price-button-with-svg', x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
            }
          }

          // Priority 4: href-based navigation links
          var links = document.querySelectorAll('a[href*="checkout"], a[href*="review"]');
          for (var link of links) {
            if (link.offsetParent !== null) {
              var text = (link.textContent || '').trim().toLowerCase();
              if (!exclude.test(text) && !orderFinalizing.test(text) && text.length < 40) {
                link.scrollIntoView({ behavior: 'instant', block: 'center' });
                var rect = link.getBoundingClientRect();
                return { found: true, text: text, href: link.href, method: 'href-match', x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
              }
            }
          }

          return { found: false };
        })()
      JS

      if btn_info && btn_info['found']
        logger.info "[PremiereProduceOne] Found checkout/review button: #{btn_info.inspect}"
        # Use CDP mouse.click — el.click() doesn't trigger React NW Pressable onPress
        browser.mouse.click(x: btn_info['x'].to_f, y: btn_info['y'].to_f)
        logger.info "[PremiereProduceOne] CDP clicked View Order at (#{btn_info['x']}, #{btn_info['y']})"
      else
        logger.warn '[PremiereProduceOne] Could not find checkout/review button'
        named_buttons = browser.evaluate(<<~JS)
          Array.from(document.querySelectorAll('button, [role="button"]'))
            .filter(function(b) {
              return b.offsetParent !== null &&
                ((b.textContent || '').trim().length > 0 || (b.getAttribute('aria-label') || '').length > 0);
            })
            .slice(0, 20)
            .map(function(b) {
              return {
                text: (b.textContent || '').trim().substring(0, 60),
                aria: (b.getAttribute('aria-label') || '').substring(0, 40),
                y: Math.round(b.getBoundingClientRect().top)
              };
            })
        JS
        logger.info "[PremiereProduceOne] All actionable buttons: #{named_buttons&.inspect}"
      end

      sleep 2
      wait_for_react_render(timeout: 5)

      # Log the resulting page state — we should now be on the review page
      current_url = browser.current_url rescue 'unknown'
      logger.info "[PremiereProduceOne] Post-click URL: #{current_url}"

      page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
      logger.info "[PremiereProduceOne] Review page text (first 500): #{page_text[0..500]}"
      logger.info "[PremiereProduceOne] Review page text (last 500): #{page_text.length > 500 ? page_text[-500..] : ''}"
    end

    def extract_checkout_data_ppo
      # On Pepper, the cart page IS the checkout page. The total is in the page
      # text (or in a sticky footer). Scroll to bottom to ensure total is visible.
      browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
      sleep 1

      checkout_data = browser.evaluate(<<~JS)
        (function() {
          var text = document.body ? document.body.innerText : '';
          var result = { total: 0, delivery_date: null, summary_text: '' };

          // Get the bottom portion of page text (where totals live)
          result.summary_text = text.substring(Math.max(0, text.length - 1500));

          // Total extraction — try bottom of page first, then full text
          var totalPatterns = [
            /order\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /grand\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /subtotal[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /total[:\\s]*\\$([\\d,]+\\.\\d{2})/i
          ];
          // Search bottom text first (more likely to have the total)
          var bottomText = text.substring(Math.max(0, text.length - 2000));
          for (var p of totalPatterns) {
            var m = bottomText.match(p);
            if (m) { result.total = parseFloat(m[1].replace(',', '')); break; }
          }

          // If no labeled total found, find the largest $ amount in the page
          // (likely the subtotal/order total)
          if (result.total === 0) {
            var amounts = (text.match(/\\$[\\d,]+\\.\\d{2}/g) || [])
              .map(function(p) { return parseFloat(p.replace(/[\\$,]/g, '')); });
            if (amounts.length > 0) result.total = Math.max.apply(null, amounts);
          }

          // Also check fixed/sticky elements for total
          if (result.total === 0) {
            var fixedEls = Array.from(document.querySelectorAll('*')).filter(function(el) {
              var style = window.getComputedStyle(el);
              return (style.position === 'fixed' || style.position === 'sticky') &&
                     el.offsetParent !== null;
            });
            for (var el of fixedEls) {
              var tc = (el.textContent || '');
              var m = tc.match(/\\$([\\d,]+\\.\\d{2})/);
              if (m) {
                var amt = parseFloat(m[1].replace(',', ''));
                if (amt > result.total) result.total = amt;
              }
            }
          }

          // Delivery date extraction — PPO uses "DELIVERY Mar 16" in the dropdown
          var datePatterns = [
            /DELIVERY\\s+(?:for\\s+)?(\\w+\\s+\\d{1,2})/i,
            /deliver(?:y|s)?[:\\s]*(\\w+day,?\\s*\\w+\\s+\\d{1,2})/i,
            /deliver(?:y|s)?\\s*(?:date)?[:\\s]*(\\w+\\s+\\d{1,2},?\\s*\\d{4})/i,
            /deliver(?:y|s)?\\s*(?:date)?[:\\s]*(\\d{1,2}\\/\\d{1,2}\\/\\d{2,4})/i,
            /available\\s*(\\w+\\s+\\d{1,2})/i
          ];
          for (var p of datePatterns) {
            var m = text.match(p);
            if (m) { result.delivery_date = m[1]; break; }
          }

          // Named buttons for diagnostics (with textContent)
          result.buttons = Array.from(document.querySelectorAll('button, [role="button"]'))
            .filter(function(b) {
              return b.offsetParent !== null && (b.textContent || '').trim().length > 0;
            })
            .slice(0, 15)
            .map(function(b) {
              return {
                text: (b.textContent || '').trim().substring(0, 60),
                y: Math.round(b.getBoundingClientRect().top)
              };
            });

          return result;
        })()
      JS

      logger.info "[PremiereProduceOne] Checkout: total=#{checkout_data['total']}, delivery=#{checkout_data['delivery_date']}"
      logger.info "[PremiereProduceOne] Checkout bottom text: #{(checkout_data['summary_text'] || '')[0..500]}"

      {
        total: checkout_data['total'].presence,
        delivery_date: checkout_data['delivery_date'],
        summary_text: checkout_data['summary_text'],
        buttons: checkout_data['buttons'] || []
      }
    end

    def click_place_order_button_ppo
      # The "Place X of Y orders (Z items)" button lives at the bottom of the
      # Order Summary overlay panel — NOT the main page.  We need to:
      #   1. Scroll WITHIN the overlay (not window.scrollTo)
      #   2. Match dynamic text like "Place 2 of 2 orders (7 items)" via regex
      #   3. Use CDP mouse.click for React Native Web Pressable components

      # Step 1: Find the button and scroll it into view within the overlay
      button_info = browser.evaluate(<<~JS)
        (function() {
          var exclude = /search|clear|close|cancel|filter|back|sign|log|add note/i;
          // Regex: "place" ... "order" with anything in between (handles "Place 2 of 2 orders (7 items)")
          var placeOrderRegex = /place.*order/i;
          var exactTargets = ['submit order', 'complete order', 'confirm order'];
          var elements = document.querySelectorAll('button, [role="button"]');

          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var text = (el.textContent || el.innerText || '').trim();
            var lowerText = text.toLowerCase();
            if (lowerText.length > 80 || lowerText.length === 0) continue;
            if (exclude.test(lowerText)) continue;

            var matched = placeOrderRegex.test(lowerText);
            if (!matched) {
              for (var target of exactTargets) {
                if (lowerText.includes(target)) { matched = true; break; }
              }
            }

            if (matched) {
              // Scroll within overlay — scrollIntoView works regardless of scroll context
              el.scrollIntoView({ behavior: 'instant', block: 'center' });
              var rect = el.getBoundingClientRect();
              return {
                found: true,
                text: text,
                x: rect.x + rect.width / 2,
                y: rect.y + rect.height / 2,
                width: rect.width,
                height: rect.height
              };
            }
          }

          // Diagnostic: list all visible button texts for debugging
          var allBtns = [];
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var t = (el.textContent || '').trim();
            if (t.length > 0 && t.length < 80) allBtns.push(t.substring(0, 60));
          }
          return { found: false, visible_buttons: allBtns.slice(0, 20) };
        })()
      JS

      logger.info "[PremiereProduceOne] Place order button search: #{button_info.inspect}"

      unless button_info && button_info['found']
        raise ScrapingError, "Could not find place order button. Visible buttons: #{button_info&.dig('visible_buttons')&.first(10)&.inspect}"
      end

      # Step 2: Click via CDP mouse (required for React Native Web Pressable)
      sleep 0.5 # Let scrollIntoView settle
      x = button_info['x'].to_f
      y = button_info['y'].to_f
      logger.warn "[PremiereProduceOne] PLACING LIVE ORDER — clicking '#{button_info['text']}' at (#{x}, #{y})"
      browser.mouse.click(x: x, y: y)
      sleep 2

      logger.info "[PremiereProduceOne] Place order button clicked successfully"
    end

    # ── Delivery date selection on the Order Summary / checkout page ──
    # PPO shows a "Cutoff: ... | DELIVERY for Mar 11" dropdown in the Order Summary panel.
    # Clicking it opens a "Select date" calendar popup with month nav, day grid, and Save button.
    #
    # The site is React Native Web (Pepper). Pressable components need CDP mouse.click
    # at coordinates — el.click() doesn't trigger the onPress handler. When CDP click
    # fails (overlay blocking, stale coordinates), we fall back to invoking the React
    # fiber's onPress directly, then to ancestor-walking clicks.
    def select_delivery_date_ppo
      return unless @target_delivery_date

      target = @target_delivery_date.is_a?(Date) ? @target_delivery_date : Date.parse(@target_delivery_date.to_s)
      target_day = target.day
      target_month_year = target.strftime('%B %Y') # e.g., "March 2026"
      target_short = "#{target.strftime('%b')} #{target_day}" # "Mar 16"

      # ── Step 0: Dismiss any leftover modals/overlays ──
      dismiss_all_modals_ppo

      # ── Step 1: Find the delivery <button> element directly ──
      # The delivery dropdown is a real <button type="button"> containing text like
      # "Cutoff: 7:00 PM ET | DELIVERY for Mar 16" with an SVG chevron.
      # Previous code searched div[class*="css-"] and walked up — but the <button>
      # itself IS the clickable element. Search <button> elements directly.
      btn_info = browser.evaluate(<<~JS)
        (function() {
          var datePattern = /\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\\w*\\s+\\d{1,2}\\b/i;
          var deliveryKeywords = /delivery|deliver|cutoff|cut-off|ship|shipping|arriving|arrival/i;

          // Priority 1: Real <button> elements (the actual Pepper delivery dropdown)
          var buttons = document.querySelectorAll('button[type="button"], button');
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            var text = (btn.textContent || btn.innerText || '').trim();
            if (text.length > 100 || text.length < 10) continue;
            if (!datePattern.test(text) || !deliveryKeywords.test(text)) continue;
            btn.scrollIntoView({ behavior: 'instant', block: 'center' });
            var rect = btn.getBoundingClientRect();
            return {
              found: true,
              text: text,
              tag: 'BUTTON',
              x: rect.x + rect.width / 2,
              y: rect.y + rect.height / 2,
              width: rect.width,
              height: rect.height
            };
          }

          // Priority 2: div[role="button"] or other elements (fallback)
          var elements = document.querySelectorAll('[role="button"], div[class*="css-"]');
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var text = (el.textContent || el.innerText || '').trim();
            if (text.length > 100 || text.length < 10) continue;
            if (!datePattern.test(text) || !deliveryKeywords.test(text)) continue;
            var hasSvg = !!el.querySelector('svg');
            if (!hasSvg) continue; // Must have the chevron SVG
            el.scrollIntoView({ behavior: 'instant', block: 'center' });
            var rect = el.getBoundingClientRect();
            return {
              found: true,
              text: text,
              tag: el.tagName,
              x: rect.x + rect.width / 2,
              y: rect.y + rect.height / 2,
              width: rect.width,
              height: rect.height
            };
          }

          return { found: false };
        })()
      JS

      unless btn_info && btn_info['found']
        logger.warn "[PremiereProduceOne] Delivery date dropdown not found — using default date"
        return
      end

      logger.info "[PremiereProduceOne] Found delivery button: tag=#{btn_info['tag']} text='#{btn_info['text']}' at (#{btn_info['x']}, #{btn_info['y']}) size=#{btn_info['width']}x#{btn_info['height']}"

      if btn_info['text'].include?(target_short)
        logger.info "[PremiereProduceOne] Delivery date already set to #{target_short} — no change needed"
        return
      end

      logger.info "[PremiereProduceOne] Selecting delivery date: #{target.strftime('%B %d, %Y')}"

      calendar_found = false
      cx = btn_info['x'].to_f
      cy = btn_info['y'].to_f

      # Check what elementFromPoint sees at the click target — if something covers
      # the button (sidebar backdrop, overlay div), CDP mouse.click would hit that
      # instead and close the sidebar.
      at_point = browser.evaluate("(function() { var el = document.elementFromPoint(#{cx}, #{cy}); return el ? { tag: el.tagName, text: (el.textContent||'').trim().substring(0,60), classes: (el.className||'').substring(0,60) } : null; })()")
      logger.info "[PremiereProduceOne] elementFromPoint at (#{cx}, #{cy}): #{at_point.inspect}"

      # Determine if the element at point IS the delivery button
      point_is_button = at_point && at_point['tag'] == 'BUTTON' && at_point['text'].to_s.length > 10

      if point_is_button
        # ── Method 1: CDP mouse.click — element at point IS the button, safe to click ──
        logger.info "[PremiereProduceOne] Method 1: CDP mouse.click on #{btn_info['tag']} at (#{cx}, #{cy})"
        browser.mouse.click(x: cx, y: cy)
        sleep 2
        calendar_found = check_calendar_open
      else
        logger.info "[PremiereProduceOne] Skipping CDP click — elementFromPoint is #{at_point&.dig('tag')}, not the delivery button (would close sidebar)"
      end

      # ── Method 2: Direct .click() on the <button> element ──
      # Use JS .click() which targets the element directly, bypassing any overlay.
      # This is the PRIMARY method when the sidebar backdrop covers the button coordinates.
      unless calendar_found
        logger.info "[PremiereProduceOne] Method 2: Direct .click() on the <button>"
        browser.evaluate(<<~JS)
          (function() {
            var datePattern = /\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\\w*\\s+\\d{1,2}\\b/i;
            var deliveryKeywords = /delivery|deliver|cutoff|cut-off|ship|shipping|arriving|arrival/i;
            var buttons = document.querySelectorAll('button');
            for (var btn of buttons) {
              if (btn.offsetParent === null) continue;
              var text = (btn.textContent || '').trim();
              if (text.length > 100 || text.length < 10) continue;
              if (datePattern.test(text) && deliveryKeywords.test(text)) {
                btn.click();
                return true;
              }
            }
            return false;
          })()
        JS
        sleep 2
        calendar_found = check_calendar_open
      end

      # ── Method 3: React fiber onPress invocation ──
      unless calendar_found
        logger.info "[PremiereProduceOne] Method 3: React fiber onPress on <button>"
        fiber_result = browser.evaluate(<<~JS)
          (function() {
            var datePattern = /\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\\w*\\s+\\d{1,2}\\b/i;
            var deliveryKeywords = /delivery|deliver|cutoff|cut-off|ship|shipping|arriving|arrival/i;
            var buttons = document.querySelectorAll('button');
            for (var btn of buttons) {
              if (btn.offsetParent === null) continue;
              var text = (btn.textContent || '').trim();
              if (text.length > 100 || text.length < 10) continue;
              if (!datePattern.test(text) || !deliveryKeywords.test(text)) continue;

              // Walk the element and its ancestors for React fiber
              var current = btn;
              for (var depth = 0; depth < 10 && current && current !== document.body; depth++) {
                var fiberKey = Object.keys(current).find(function(k) {
                  return k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$');
                });
                if (fiberKey) {
                  var fiber = current[fiberKey];
                  var fw = 0;
                  while (fiber && fw < 20) {
                    if (fiber.memoizedProps && typeof (fiber.memoizedProps.onPress || fiber.memoizedProps.onClick) === 'function') {
                      try {
                        var handler = fiber.memoizedProps.onPress || fiber.memoizedProps.onClick;
                        handler({ nativeEvent: {}, preventDefault: function(){}, stopPropagation: function(){} });
                        return { success: true, depth: depth, fiberWalk: fw };
                      } catch(e) {
                        return { success: false, reason: 'handler threw: ' + e.message };
                      }
                    }
                    fiber = fiber.return;
                    fw++;
                  }
                }
                current = current.parentElement;
              }
              return { success: false, reason: 'no handler found' };
            }
            return { success: false, reason: 'button not found' };
          })()
        JS
        logger.info "[PremiereProduceOne] Fiber result: #{fiber_result.inspect}"
        sleep 2
        calendar_found = check_calendar_open
      end

      unless calendar_found
        begin
          screenshot_path = "/tmp/ppo_delivery_debug_#{Time.current.strftime('%H%M%S')}.png"
          browser.screenshot(path: screenshot_path)
          logger.info "[PremiereProduceOne] Debug screenshot: #{screenshot_path}"
        rescue => e
          logger.warn "[PremiereProduceOne] Screenshot failed: #{e.message}"
        end
        logger.warn "[PremiereProduceOne] All 3 methods failed to open calendar — using default delivery date"
        return
      end

      # ── Step 2: Navigate to correct month if needed ──
      6.times do |nav_attempt|
        current_month = browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('*');
            for (var el of els) {
              if (el.children.length > 0) continue;
              var text = (el.textContent || '').trim();
              if (/^\\w+ \\d{4}$/.test(text) && /january|february|march|april|may|june|july|august|september|october|november|december/i.test(text)) {
                return text;
              }
            }
            return null;
          })()
        JS

        logger.info "[PremiereProduceOne] Calendar showing: #{current_month || 'unknown'}"

        if current_month && current_month.downcase == target_month_year.downcase
          break
        end

        if nav_attempt >= 5
          logger.warn "[PremiereProduceOne] Could not navigate to #{target_month_year} after 6 attempts"
          break
        end

        next_arrow = browser.evaluate(<<~JS)
          (function() {
            var buttons = document.querySelectorAll('button, [role="button"]');
            for (var btn of buttons) {
              if (btn.offsetParent === null) continue;
              var text = (btn.textContent || btn.innerText || '').trim();
              var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
              if (text === '>' || text === '\\u203A' || text === '\\u25B8' || aria.includes('next') || aria.includes('forward')) {
                var rect = btn.getBoundingClientRect();
                if (rect.width > 0 && rect.width < 80) {
                  return { found: true, x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
                }
              }
            }
            return { found: false };
          })()
        JS

        if next_arrow && next_arrow['found']
          browser.mouse.click(x: next_arrow['x'].to_f, y: next_arrow['y'].to_f)
          sleep 0.5
        else
          logger.warn "[PremiereProduceOne] Next month arrow not found"
          break
        end
      end

      # ── Step 3: Click the target day ──
      day_info = browser.evaluate(<<~JS)
        (function() {
          var targetDay = #{target_day};
          var candidates = document.querySelectorAll('*');
          var dayElements = [];
          for (var el of candidates) {
            if (el.children.length > 0) continue;
            if (el.offsetParent === null) continue;
            var text = (el.textContent || '').trim();
            if (text === String(targetDay)) {
              var rect = el.getBoundingClientRect();
              if (rect.width > 10 && rect.width < 80 && rect.height > 10 && rect.height < 80) {
                var style = window.getComputedStyle(el);
                if (parseFloat(style.opacity) < 0.5) continue;
                dayElements.push({ x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, width: rect.width, height: rect.height });
              }
            }
          }
          if (dayElements.length === 0) return { found: false };
          dayElements.sort(function(a, b) { return (b.width * b.height) - (a.width * a.height); });
          return { found: true, x: dayElements[0].x, y: dayElements[0].y, count: dayElements.length };
        })()
      JS

      unless day_info && day_info['found']
        logger.warn "[PremiereProduceOne] Day #{target_day} not found in calendar — using default date"
        browser.evaluate("(function() { var x = document.querySelector('[aria-label=\"close\"], [aria-label=\"Close\"]'); if (x) x.click(); })()")
        sleep 0.5
        return
      end

      logger.info "[PremiereProduceOne] Clicking day #{target_day} at (#{day_info['x']}, #{day_info['y']})"
      browser.mouse.click(x: day_info['x'].to_f, y: day_info['y'].to_f)
      sleep 0.5

      # ── Step 4: Click "Save" ──
      save_btn = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('button, [role="button"]');
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            var text = (btn.textContent || btn.innerText || '').trim().toLowerCase();
            if (text === 'save') {
              var rect = btn.getBoundingClientRect();
              return { found: true, x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
            }
          }
          return { found: false };
        })()
      JS

      if save_btn && save_btn['found']
        logger.info "[PremiereProduceOne] Clicking Save button"
        browser.mouse.click(x: save_btn['x'].to_f, y: save_btn['y'].to_f)
        sleep 2
      else
        logger.warn "[PremiereProduceOne] Save button not found — date may not be saved"
      end

      # ── Step 5: Verify delivery date updated ──
      sleep 2
      updated_text = browser.evaluate(<<~JS)
        (function() {
          var datePattern = /\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\\w*\\s+\\d{1,2}\\b/i;
          var deliveryKeywords = /delivery|deliver|cutoff|cut-off|ship|shipping|arriving|arrival/i;
          var elements = document.querySelectorAll('button, [role="button"], [class*="Pressable"], div[class*="css-"]');
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var text = (el.textContent || el.innerText || '').trim();
            if (text.length > 100 || text.length < 10) continue;
            if (datePattern.test(text) && deliveryKeywords.test(text)) {
              return text;
            }
          }
          return null;
        })()
      JS

      if updated_text
        logger.info "[PremiereProduceOne] Delivery date after selection: #{updated_text}"
        if updated_text.include?(target_short)
          logger.info "[PremiereProduceOne] Delivery date confirmed: #{target_short}"
        else
          logger.warn "[PremiereProduceOne] Expected #{target_short}, got: #{updated_text}"
        end
      end
    end

    # Helper: check if the "Select date" calendar modal is open
    def check_calendar_open
      browser.evaluate("(function() { return /select date/i.test(document.body ? document.body.innerText : ''); })()")
    end

    def wait_for_order_confirmation_ppo
      start_time = Time.current
      timeout = 90
      pre_click_url = browser.current_url rescue ''

      loop do
        page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
        current_url = browser.current_url rescue ''
        elapsed = (Time.current - start_time).round(1)

        # Detection 1: URL changed to a confirmation/success/thank-you page
        url_changed = current_url != pre_click_url && current_url.match?(/confirm|success|thank|receipt|complete/i)

        # Detection 2: Page text contains confirmation keywords
        # PPO shows "Your order is queued" on successful submit
        text_confirmed = page_text.match?(/confirmation|order\s*(?:placed|submitted|received|complete|queued)|thank\s*you|order\s*#|successfully|order is queued/i)

        if url_changed || text_confirmed
          logger.info "[PremiereProduceOne] Order confirmed after #{elapsed}s (url_changed=#{url_changed}, text_confirmed=#{text_confirmed})"

          conf_match = page_text.match(/order\s*#?\s*[:\s]*([A-Z0-9-]+)/i) ||
                       page_text.match(/confirmation\s*#?\s*[:\s]*([A-Z0-9-]+)/i) ||
                       page_text.match(/#(\d{4,})/)
          total_match = page_text.match(/total[:\s]*\$([\d,]+\.\d{2})/i)
          date_match = page_text.match(/deliver(?:y|s)?[:\s]*([\w\s,]+\d{1,2})/i)

          return {
            confirmation_number: conf_match ? conf_match[1] : "PPO-#{Time.current.strftime('%Y%m%d%H%M%S')}",
            total: total_match ? total_match[1].gsub(',', '').to_f : nil,
            delivery_date: date_match ? date_match[1].strip : nil
          }
        end

        # Detection 3: Cart is now empty (order went through and cleared the cart)
        # Only check after giving the confirmation page a chance to load (15s+)
        if elapsed > 15 && current_url != pre_click_url
          cart_empty = page_text.match?(/cart is empty|no items in|your order has been|order is queued/i)
          if cart_empty
            logger.info "[PremiereProduceOne] Cart empty after submit — order likely placed (#{elapsed}s)"
            return {
              confirmation_number: "PPO-#{Time.current.strftime('%Y%m%d%H%M%S')}",
              total: nil,
              delivery_date: nil
            }
          end
        end

        if page_text.match?(/error|failed|could not|unable to/i) && !page_text.match?(/confirmation|success|submitted|complete/i)
          raise ScrapingError, "Checkout failed: #{page_text[0..300]}"
        end

        if Time.current - start_time > timeout
          logger.error "[PremiereProduceOne] Checkout confirmation timeout (#{timeout}s)"
          logger.error "[PremiereProduceOne] Final URL: #{current_url}"
          logger.error "[PremiereProduceOne] Final page text (first 500): #{page_text[0..500]}"
          raise ScrapingError, "Checkout confirmation timeout (#{timeout}s) — order may have been placed, check PPO directly"
        end

        sleep 2
      end
    end

    def remove_all_cart_items_ppo
      # Pepper React Native Web cart removal:
      #   - When qty > 1: "Decrease quantity" button (minus icon)
      #   - When qty = 1: trash/delete button replaces the minus
      # Strategy: click decrease/trash buttons ONLY. NEVER click "Increase quantity".
      max_clicks = 2000 # Safety limit for total clicks
      removed_count = 0
      click_count = 0

      loop do
        break if click_count >= max_clicks

        result = browser.evaluate(<<~JS)
          (function() {
            var buttons = document.querySelectorAll('button, [role="button"]');
            for (var btn of buttons) {
              if (btn.offsetParent === null) continue;
              var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
              var text = (btn.textContent || '').trim().toLowerCase();

              // Match decrease quantity, trash, remove, delete buttons
              if (aria.includes('decrease') || aria.includes('trash') ||
                  aria.includes('remove') || aria.includes('delete') ||
                  text === 'remove' || text === 'delete') {
                btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                btn.click();
                return { clicked: true, aria: aria, text: text };
              }
            }
            return { clicked: false };
          })()
        JS

        break if result.nil? || !result['clicked']

        click_count += 1
        is_trash = (result['aria'] || '').match?(/trash|remove|delete/)
        removed_count += 1 if is_trash

        sleep 0.3
        if is_trash
          sleep 0.5
          confirm_pepper_modal
          sleep 0.5
        end

        logger.info "[PremiereProduceOne] Cart item click ##{click_count}: aria=#{result['aria']}" if click_count <= 5 || click_count % 20 == 0
      end

      logger.info "[PremiereProduceOne] Removed #{removed_count} cart items (#{click_count} total clicks)"
    end
  end
end
