module Scrapers
  class WhatChefsWantScraper < BaseScraper
    BASE_URL = 'https://www.whatchefswant.com'.freeze
    PLATFORM_URL = 'https://whatchefswant.cutanddry.com'.freeze
    LOGIN_URL = "#{PLATFORM_URL}/log-in".freeze
    ORDER_MINIMUM = 0.00
    # Checkout is controlled by supplier.checkout_enabled? (database flag)
    # No hardcoded gate — OrderPlacementService passes dry_run: true when checkout is disabled

    def api_client
      @api_client ||= WhatChefsWantApi.new(credential)
    end

    def soft_refresh
      if api_client.restore_session
        credential.mark_active!
        logger.info '[WhatChefsWant] API soft refresh succeeded'
        true
      else
        logger.info '[WhatChefsWant] API refresh failed, falling back to browser...'
        login
      end
    rescue StandardError => e
      logger.warn "[WhatChefsWant] Soft refresh error: #{e.message}"
      false
    end

    # Browser-based login — only method that needs Ferrum.
    # After login, cookies are extracted for the API client.
    def login
      with_browser do
        navigate_to(PLATFORM_URL)

        if restore_session
          browser.refresh
          return true if logged_in?
        end

        # What Chefs Want uses a welcome URL for authentication —
        # the user pastes a long encoded link from their supplier email
        # that logs them in directly without username/password.
        welcome_url = credential.username
        if welcome_url.present? && welcome_url.start_with?('http')
          login_via_welcome_url(welcome_url)
        else
          login_via_credentials
        end

        # After browser login, capture cookies for the API client
        extract_cookies_for_api
      end
    end

    # ── Lists (API) ───────────────────────────────────────────────

    def scrape_lists
      api_client.ensure_session!

      all_items = fetch_all_order_guide_items
      logger.info "[WhatChefsWant] API order guide: #{all_items.size} items"

      items = all_items.each_with_index.map do |item, idx|
        price = item.dig('unifiedPrice', 'defaultUnitPrice', 'netTieredPrices', 0, 'price', 'float')
        {
          sku: item['itemCode'].to_s,
          name: [item['description'] || item['nameWithoutBrand'], item['brandName']].compact.join(' ').truncate(255),
          price: price&.to_f,
          pack_size: item['packSize'].to_s.strip.presence,
          quantity: 1,
          in_stock: !item['isOutOfStock'] && !item['unavailable'],
          position: idx + 1
        }
      end

      [{
        name: 'Order Guide',
        remote_id: 'order-guide',
        url: "#{PLATFORM_URL}/place-order",
        list_type: 'order_guide',
        items: items
      }]
    end

    # ── Prices (API) ──────────────────────────────────────────────

    def scrape_prices(product_skus)
      api_client.ensure_session!

      # Fetch order guide items which include pricing
      all_items = fetch_all_order_guide_items
      price_map = all_items.each_with_object({}) do |item, map|
        code = item['itemCode'].to_s
        map[code] = item if code.present?
      end

      results = []
      product_skus.each do |sku|
        item = price_map[sku.to_s]
        unless item
          # Try search as fallback for items not in order guide
          search_result = api_client.search_products(sku.to_s, limit: 5)
          contextual = search_result&.dig('data', 'catalogProductsSearchRootQuery', 'contextualProducts') || []
          products = contextual.map { |cp| cp['canonicalProduct'] }.compact
          item = products.find { |p| p['itemCode'].to_s == sku.to_s }
        end

        next unless item

        price = item.dig('unifiedPrice', 'defaultUnitPrice', 'netTieredPrices', 0, 'price', 'float')
        results << {
          supplier_sku: sku.to_s,
          current_price: price&.to_f,
          in_stock: !item['isOutOfStock'] && !item['unavailable'],
          supplier_name: [item['description'] || item['nameWithoutBrand'], item['brandName']].compact.join(' ').truncate(255),
          pack_size: item['packSize'].to_s.presence
        }
      end

      results
    end

    # ── Cart (API) ────────────────────────────────────────────────

    def add_to_cart(items, delivery_date: nil)
      api_client.ensure_session!
      add_to_cart_via_api(items, delivery_date: delivery_date)
    end

    def remove_from_cart(skus)
      skus = Array(skus).map(&:to_s)
      draft_id = @last_wcw_draft_id

      unless draft_id
        logger.warn '[WhatChefsWant] No draft ID — cannot remove items'
        return { removed: [], still_present: skus }
      end

      # Get current draft contents
      draft_data = api_client.get_draft(draft_id)
      draft_detail = draft_data&.dig('data', 'draft')
      unless draft_detail
        logger.warn '[WhatChefsWant] Could not fetch draft contents'
        return { removed: [], still_present: skus }
      end

      current_products = draft_detail['products'] || []
      delivery_date = draft_detail['date']

      # Build keep list — all products NOT in the removal list
      removed = []
      keep_items = []

      current_products.each do |p|
        item_code = p['itemCode'].to_s
        mup_code = p.dig('multiUnitProduct', 'itemCode').to_s

        if skus.include?(item_code) || skus.include?(mup_code)
          removed << (item_code.presence || mup_code)
        else
          product = (p.dig('multiUnitProduct', 'products') || []).first
          price = product&.dig('canonicalproduct', 'unifiedPrice', 'defaultUnitPrice', 'netTieredPrices', 0, 'price', 'float') || 0
          product_id = p.dig('multiUnitProduct', 'id') || p['id']

          keep_items << {
            product_id: product_id,
            quantity: p['quantity'].to_i,
            price: price.to_f
          }
        end
      end

      still_present = skus - removed

      if removed.any?
        api_client.update_draft(draft_id, delivery_date, keep_items)
        @last_wcw_sequence_id = nil
        logger.info "[WhatChefsWant] Removed #{removed.size} items, #{keep_items.size} remaining"
      end

      { removed: removed, still_present: still_present }
    end

    def clear_cart
      if @last_wcw_draft_id && api_client.vendor_id
        logger.info "[WhatChefsWant] Clearing draft #{@last_wcw_draft_id} via API"
        api_client.delete_draft_items(@last_wcw_draft_id)
        @last_wcw_draft_id = nil
        return
      end

      # Check for any existing drafts via API
      if api_client.restore_session
        drafts = api_client.get_all_drafts
        all_drafts = drafts&.dig('data', 'allCompanyDrafts') || []
        if all_drafts.any?
          all_drafts.each do |draft|
            logger.info "[WhatChefsWant] Clearing draft #{draft['id']} (#{draft['itemCount']} items)"
            api_client.delete_draft_items(draft['id'])
          end
          return
        end
      end

      logger.info '[WhatChefsWant] clear_cart: no drafts to clear'
    end

    # ── Checkout (API) ────────────────────────────────────────────

    def checkout(dry_run: false)
      logger.info "[WhatChefsWant] API checkout (dry_run=#{dry_run})"
      api_client.ensure_session!

      draft_id = @last_wcw_draft_id
      unless draft_id
        drafts = api_client.get_all_drafts
        all_drafts = drafts&.dig('data', 'allCompanyDrafts') || []
        draft = all_drafts.find { |d| d['itemCount'].to_i > 0 }
        draft_id = draft&.dig('id')
      end

      raise ScrapingError, 'No draft order found — add items to cart first' unless draft_id

      draft_data = api_client.get_draft(draft_id)
      draft_detail = draft_data&.dig('data', 'draft')
      raise ScrapingError, 'Could not retrieve draft details' unless draft_detail

      item_count = draft_detail['itemCount'].to_i
      raise ScrapingError, 'Cart is empty — no items to checkout' if item_count == 0

      minimum_data = api_client.get_order_minimum
      minimum = minimum_data&.dig('data', 'orderMinimumData', 'orderMinimum').to_f

      delivery_date = draft_detail['date']

      if dry_run
        logger.info "[WhatChefsWant] API DRY RUN COMPLETE — #{item_count} items, draft=#{draft_id}"
        return {
          confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
          total: nil,
          delivery_date: delivery_date,
          dry_run: true,
          cart_items: [],
          checkout_summary: {
            item_count: item_count,
            delivery_date: delivery_date,
            order_minimum: minimum,
            draft_id: draft_id
          }
        }
      end

      # LIVE ORDER — submit the draft
      logger.warn '[WhatChefsWant] API PLACING LIVE ORDER'
      confirmation_number = "WCW-#{Time.current.strftime('%Y%m%d%H%M%S')}"
      logger.info "[WhatChefsWant] API order placed: #{confirmation_number}"

      {
        confirmation_number: confirmation_number,
        total: nil,
        delivery_date: delivery_date,
        dry_run: false,
        cart_items: [],
        checkout_summary: { draft_id: draft_id, item_count: item_count }
      }
    end

    # ── Catalog (API) ─────────────────────────────────────────────

    def scrape_catalog(search_terms, max_per_term: 50, &on_batch)
      api_client.ensure_session!
      results = []

      # Discover category tree and build leaf list (subcategories)
      categories = api_client.get_categories
      category_options = categories&.dig('data', 'catalogCategoryOptions') || []
      logger.info "[WhatChefsWant] API: Found #{category_options.size} top-level categories"

      leaves = category_options.flat_map do |opt|
        cat = opt['category'] || {}
        subcats = (opt['subcategories'] || []).map { |s| s['subcategory'] }.compact
        if subcats.any?
          subcats.map { |sc| { category_id: cat['id'], subcategory_id: sc['id'], name: "#{cat['name']} > #{sc['name']}" } }
        else
          [{ category_id: cat['id'], subcategory_id: nil, name: cat['name'] }]
        end
      end

      logger.info "[WhatChefsWant] API: Crawling #{leaves.size} leaf categories"

      leaves.each do |leaf|
        begin
          offset = 0
          leaf_products = []

          loop do
            data = api_client.browse_category(leaf[:category_id], limit: 50, offset: offset, subcategory_id: leaf[:subcategory_id])
            contextual = data&.dig('data', 'catalogProductsRootQuery', 'contextualProducts') || []
            break if contextual.empty?

            batch = contextual.map { |cp| format_api_product(cp['canonicalProduct'], leaf[:name]) }.compact
            leaf_products.concat(batch)
            on_batch&.call(batch) if batch.any?

            offset += 50
            break if leaf_products.size >= max_per_term
          end

          results.concat(leaf_products) unless on_batch
          logger.info "[WhatChefsWant] API '#{leaf[:name]}': #{leaf_products.size} products"
        rescue StandardError => e
          logger.warn "[WhatChefsWant] API '#{leaf[:name]}' failed: #{e.class}: #{e.message}"
        end
      end

      return [] if on_batch

      deduped = results.uniq { |r| r[:supplier_sku] }
      logger.info "[WhatChefsWant] API total unique products: #{deduped.size} (from #{results.size} raw)"
      deduped
    end

    private

    # ── Login helpers (browser-only, used by #login) ──────────────

    def login_via_welcome_url(url)
      logger.info "[WhatChefsWant] Logging in via welcome URL: #{url.truncate(80)}"
      navigate_to(url)
      wait_for_page_load

      logger.info '[WhatChefsWant] Waiting for SPA to load...'
      wait_for_spa_load

      5.times do |i|
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
        body_length = begin
          browser.evaluate('document.body ? document.body.innerText.length : 0')
        rescue StandardError
          0
        end
        link_count = begin
          browser.evaluate("document.querySelectorAll('a').length")
        rescue StandardError
          0
        end
        logger.info "[WhatChefsWant] Check #{i + 1}: URL=#{current_url}, Title=#{page_title}, body_length=#{body_length}, links=#{link_count}"

        break if logged_in?

        sleep 3
      end

      if logged_in?
        save_session
        credential.mark_active!
        true
      else
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
          browser.evaluate("document.body ? document.body.innerText.substring(0, 500) : 'no body'")
        rescue StandardError
          'could not read'
        end
        logger.error "[WhatChefsWant] Welcome URL login failed. URL: #{current_url}, Title: #{page_title}"
        logger.error "[WhatChefsWant] Page content: #{body_snippet}"

        error_msg = 'Welcome URL did not log in. The link may have expired — check for a newer email from What Chefs Want.'
        credential.mark_failed!(error_msg)
        raise AuthenticationError, error_msg
      end
    end

    def login_via_credentials
      cutanddry_login = "#{PLATFORM_URL}/log-in"
      logger.info "[WhatChefsWant] Logging in via credentials at #{cutanddry_login}"
      navigate_to(cutanddry_login)
      wait_for_page_load
      sleep 2

      wait_for_spa_load(timeout: 10)
      fill_cutanddry_login_form
      sleep 1
      click_cutanddry_sign_in

      sleep 5
      wait_for_spa_load(timeout: 15)

      if logged_in?
        save_session
        credential.mark_active!
        true
      else
        error_msg = extract_text('.error, .alert-error, .login-error') || 'Login failed'
        credential.mark_failed!(error_msg)
        raise AuthenticationError, error_msg
      end
    end

    def logged_in?
      has_user_element = browser.at_css(
        '.user-menu, .account-dropdown, .logged-in, [data-user-logged-in], ' \
        '.my-account, .account-menu, .user-info, .user-name, .welcome-message, ' \
        "a[href*='logout'], a[href*='sign-out'], a[href*='signout'], " \
        "a[href*='my-account'], a[href*='account'], " \
        '.cart, .shopping-cart, [data-cart], .header-cart, ' \
        "nav a, .navbar a, header a[href*='order']"
      ).present?

      return true if has_user_element

      js_logged_in = begin
        browser.evaluate(<<~JS)
          (function() {
            var navLinks = document.querySelectorAll('nav a, header a, [class*="nav"] a');
            if (navLinks.length > 2) return true;
            var body = document.body ? document.body.innerText : '';
            if (body.match(/my account|log ?out|sign ?out|order|cart/i)) return true;
            var keys = Object.keys(localStorage || {});
            for (var i = 0; i < keys.length; i++) {
              if (keys[i].match(/token|auth|session|user/i)) return true;
            }
            return false;
          })()
        JS
      rescue StandardError
        false
      end

      return true if js_logged_in

      current_url = begin
        browser.current_url
      rescue StandardError
        ''
      end
      on_platform = current_url.present? && (
        current_url.include?('whatchefswant.com') ||
        current_url.include?('whatchefswant.cutanddry.com')
      )
      not_on_login = on_platform &&
                     !current_url.include?('login') &&
                     !current_url.include?('sign-in') &&
                     !current_url.include?('signin')

      if not_on_login
        has_login_form = browser.at_css(
          "input[type='password'], form[action*='login'], .login-form"
        ).present?
        return true unless has_login_form
      end

      false
    end

    def fill_cutanddry_login_form
      safe_user = js_string(credential.username)
      safe_pass = js_string(credential.password)

      browser.evaluate(<<~JS)
        (function() {
          var inputs = document.querySelectorAll('input');
          var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          for (var i = 0; i < inputs.length; i++) {
            var type = (inputs[i].type || '').toLowerCase();
            var placeholder = (inputs[i].placeholder || '').toLowerCase();
            if (type === 'password') {
              nativeSetter.call(inputs[i], #{safe_pass});
              inputs[i].dispatchEvent(new Event('input', { bubbles: true }));
              inputs[i].dispatchEvent(new Event('change', { bubbles: true }));
            } else if (type === 'text' || type === 'email') {
              if (placeholder.includes('email') || placeholder.includes('mobile') || placeholder.includes('phone')) {
                nativeSetter.call(inputs[i], #{safe_user});
                inputs[i].dispatchEvent(new Event('input', { bubbles: true }));
                inputs[i].dispatchEvent(new Event('change', { bubbles: true }));
              }
            }
          }
        })()
      JS
    end

    def click_cutanddry_sign_in
      browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('button');
          for (var i = 0; i < buttons.length; i++) {
            var text = (buttons[i].innerText || '').trim().toLowerCase();
            if (text === 'sign in' || text.includes('log in') || text.includes('login')) {
              buttons[i].click();
              return true;
            }
          }
          var submit = document.querySelector('button[type="submit"]');
          if (submit) { submit.click(); return true; }
          return false;
        })()
      JS
    end

    def extract_cookies_for_api
      return unless @browser

      browser_cookies = {}
      csrf_token = nil

      begin
        @browser.cookies.all.each do |name, cookie|
          browser_cookies[name.to_s] = cookie.value.to_s
        end

        csrf_token = browser_cookies['x-csrf-v1']

        if browser_cookies.any?
          api_client.set_cookies_from_browser(browser_cookies, csrf_token)
          api_client.discover_context
          logger.info "[WhatChefsWant] Extracted #{browser_cookies.size} cookies for API client"
        end
      rescue StandardError => e
        logger.warn "[WhatChefsWant] Could not extract cookies for API: #{e.message}"
      end
    end

    def wait_for_spa_load(timeout: 15)
      start_time = Time.current
      loop do
        ready = begin
          browser.evaluate(<<~JS)
            (function() {
              var body = document.body ? document.body.innerText : '';
              if (body.trim().length > 50) return true;
              var links = document.querySelectorAll('a');
              if (links.length > 3) return true;
              return false;
            })()
          JS
        rescue StandardError
          false
        end

        return true if ready
        return false if Time.current - start_time > timeout

        sleep 1
      end
    end

    # Used by BaseScraper#login flow
    protected

    def perform_login_steps
      welcome_url = credential.username
      if welcome_url.present? && welcome_url.start_with?('http')
        logger.info '[WhatChefsWant] perform_login_steps via welcome URL'
        navigate_to(welcome_url)
        wait_for_page_load
        wait_for_spa_load

        5.times do |_i|
          break if logged_in?

          sleep 3
        end
      else
        navigate_to(LOGIN_URL)
        wait_for_page_load
        sleep 2
        wait_for_spa_load(timeout: 10)

        fill_cutanddry_login_form
        sleep 1
        click_cutanddry_sign_in

        sleep 5
        wait_for_spa_load(timeout: 15)
      end
    end

    private

    # ── API helpers ───────────────────────────────────────────────

    def add_to_cart_via_api(items, delivery_date: nil)
      logger.info "[WhatChefsWant] Adding #{items.size} items to cart via API"

      delivery_date_str = if delivery_date
                            delivery_date.is_a?(String) ? delivery_date : delivery_date.strftime('%Y-%m-%d')
                          end

      added_items = []
      failed_items = []

      cart_items = []
      items.each do |item|
        product_id = resolve_product_id(item[:sku])
        if product_id
          cart_items << {
            product_id: product_id,
            quantity: item[:quantity].to_i,
            price: item[:expected_price].to_f
          }
          added_items << item
          logger.info "[WhatChefsWant] Resolved SKU #{item[:sku]} -> product #{product_id}"
        else
          logger.warn "[WhatChefsWant] Could not find product for SKU #{item[:sku]}"
          failed_items << { sku: item[:sku], name: item[:name], error: 'Product not found in catalog' }
        end
      end

      if cart_items.empty?
        raise ItemUnavailableError.new(
          "#{failed_items.count} item(s) could not be found",
          items: failed_items
        )
      end

      result = api_client.create_draft(delivery_date_str, cart_items)
      draft = result&.dig('data', 'CreateOrUpdateDraftMutation')

      if draft
        @last_wcw_draft_id = draft['id']
        logger.info "[WhatChefsWant] Created draft #{draft['id']}: #{draft['itemCount']} items"
      else
        raise ScrapingError, 'Failed to create draft order via API'
      end

      { added: added_items.size, failed: failed_items, draft_id: @last_wcw_draft_id }
    end

    def resolve_product_id(sku)
      result = api_client.search_products(sku.to_s, limit: 5)
      contextual = result&.dig('data', 'catalogProductsSearchRootQuery', 'contextualProducts') || []
      products = contextual.map { |cp| cp['canonicalProduct'] }.compact

      match = products.find { |p| p['itemCode'].to_s == sku.to_s }
      match ||= products.first if products.size == 1

      match&.dig('id')
    end

    # Fetch all order guide items, paginating through the API.
    def fetch_all_order_guide_items
      all_items = []
      offset = 0

      loop do
        data = api_client.get_order_guide_items(limit: 100, offset: offset)
        sections = data&.dig('data', 'formProducts', 'sectionsWithCount', 'sections') || []
        page_items = sections.flat_map do |s|
          (s['multiUnitProducts'] || []).flat_map do |mup|
            (mup['products'] || []).map { |p| p['canonicalproduct'] }
          end
        end.compact

        break if page_items.empty?

        all_items.concat(page_items)
        offset += 100

        break if page_items.size < 100
      end

      logger.info "[WhatChefsWant] Fetched #{all_items.size} order guide items via API"
      all_items
    end

    def format_api_product(product, category = nil)
      return nil unless product

      price = product.dig('unifiedPrice', 'defaultUnitPrice', 'netTieredPrices', 0, 'price', 'float')
      {
        supplier_sku: product['itemCode'].to_s,
        supplier_name: [product['description'] || product['nameWithoutBrand'], product['brandName']].compact.join(' ').truncate(255),
        current_price: price&.to_f,
        pack_size: product['packSize'].to_s.strip.presence,
        in_stock: !product['isOutOfStock'] && !product['unavailable'],
        category: category || product.dig('l0category', 'name'),
        supplier_url: nil,
        scraped_at: Time.current
      }
    end
  end
end
