module Scrapers
  class WhatChefsWantScraper < BaseScraper
    BASE_URL = 'https://www.whatchefswant.com'.freeze
    PLATFORM_URL = 'https://whatchefswant.cutanddry.com'.freeze
    LOGIN_URL = "#{PLATFORM_URL}/log-in".freeze
    ORDER_MINIMUM = 0.00
    # Checkout is controlled by supplier.checkout_enabled? (database flag)
    # No hardcoded gate — OrderPlacementService passes dry_run: true when checkout is disabled

    # What Chefs Want (Cut+Dry platform) categories for catalog browsing
    # Categories are browsed via filter buttons on the order page
    WCW_CATEGORIES = [
      { name: 'Produce', filter: 'Produce' },
      { name: 'Meat', filter: 'Meat' },
      { name: 'Poultry', filter: 'Poultry' },
      { name: 'Seafood', filter: 'Seafood' },
      { name: 'Dairy', filter: 'Dairy' },
      { name: 'Dry Goods', filter: 'Dry Goods' },
      { name: 'Beverages', filter: 'Beverages' },
      { name: 'Paper & Disposables', filter: 'Paper' },
      { name: 'Chemicals & Cleaners', filter: 'Chemicals' },
      { name: 'Equipment', filter: 'Equipment' }
    ].freeze

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

    private

    def login_via_welcome_url(url)
      logger.info "[WhatChefsWant] Logging in via welcome URL: #{url.truncate(80)}"
      navigate_to(url)
      wait_for_page_load

      # The welcome URL (email.cutanddry.com/c/...) redirects to
      # whatchefswant.cutanddry.com (a React SPA white-label platform).
      # We need to wait for: 1) redirects to complete, 2) React to hydrate/render.
      # The page body initially shows just "Home" until React mounts.
      logger.info '[WhatChefsWant] Waiting for SPA to load...'
      wait_for_spa_load

      # Check login state after SPA has loaded
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

        # Wait for additional JS rendering
        sleep 3
      end

      if logged_in?
        save_session
        credential.mark_active!
        true
      else
        # Log the page content for debugging
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
      # Login on the Cut+Dry platform directly (not the WordPress site)
      # so we get session cookies for the API client.
      cutanddry_login = "#{PLATFORM_URL}/log-in"
      logger.info "[WhatChefsWant] Logging in via credentials at #{cutanddry_login}"
      navigate_to(cutanddry_login)
      wait_for_page_load
      sleep 2

      # Wait for the React SPA login form to render
      wait_for_spa_load(timeout: 10)

      # Fill email and password — Cut+Dry uses React so we need JS-based filling
      fill_cutanddry_login_form

      sleep 1

      # Click the Sign In button
      click_cutanddry_sign_in

      # Wait for login to complete and SPA to redirect
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

    public

    def logged_in?
      # The WCW platform lives on whatchefswant.cutanddry.com (React SPA).
      # After welcome URL login, the browser ends up there.

      # 1. Look for common logged-in UI elements
      has_user_element = browser.at_css(
        '.user-menu, .account-dropdown, .logged-in, [data-user-logged-in], ' \
        '.my-account, .account-menu, .user-info, .user-name, .welcome-message, ' \
        "a[href*='logout'], a[href*='sign-out'], a[href*='signout'], " \
        "a[href*='my-account'], a[href*='account'], " \
        '.cart, .shopping-cart, [data-cart], .header-cart, ' \
        "nav a, .navbar a, header a[href*='order']"
      ).present?

      return true if has_user_element

      # 2. Check via JavaScript — look for React-rendered auth state or nav elements
      js_logged_in = begin
        browser.evaluate(<<~JS)
          (function() {
            // Check for any navigation links (React SPA renders these when logged in)
            var navLinks = document.querySelectorAll('nav a, header a, [class*="nav"] a');
            if (navLinks.length > 2) return true;

            // Check for user-related text content
            var body = document.body ? document.body.innerText : '';
            if (body.match(/my account|log ?out|sign ?out|order|cart/i)) return true;

            // Check for auth tokens in localStorage
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

      # 3. Check if we're on the platform (cutanddry.com) and NOT on a login page
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

    def scrape_prices(product_skus)
      results = []

      with_browser do
        # Restore session inline — do NOT call login() which has its own
        # with_browser block and would create a nested browser (killing ours).
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          sleep 2
        end
        unless logged_in?
          perform_login_steps
          raise AuthenticationError, 'Could not log in for price verification' unless logged_in?
        end
        save_session

        product_skus.each do |sku|
          begin
            result = scrape_product(sku)
            results << result if result
          rescue ScrapingError => e
            logger.warn "[WhatChefsWant] Failed to scrape SKU #{sku}: #{e.message}"
          end

          rate_limit_delay
        end
      end

      results
    end

    def add_to_cart(items, delivery_date: nil)
      @target_delivery_date = delivery_date

      # Try API-based cart first
      if api_client.restore_session
        return add_to_cart_via_api(items, delivery_date: delivery_date)
      end

      # Fall back to browser-based cart
      logger.info '[WhatChefsWant] API session not available, using browser for add_to_cart'
      add_to_cart_via_browser(items, delivery_date: delivery_date)
    end

    private

    # Add a single item by searching for its SKU on the Order Guide,
    # then setting the quantity via the React-compatible nativeSetter pattern.
    def add_single_item_to_cart(item)
      sku = item[:sku].to_s
      qty = item[:quantity].to_i
      raise ScrapingError, "Invalid quantity for SKU #{sku}" if qty <= 0

      ensure_on_order_page

      # Search for the item by SKU code on the Order Guide
      perform_order_page_search(sku)

      # Verify the item appears in results
      page_text = begin
        browser.evaluate("document.body ? document.body.innerText : ''")
      rescue StandardError
        ''
      end
      raise ScrapingError, "Product SKU #{sku} not found in search results" unless page_text.include?(sku)

      # Check if item is available
      if page_text.include?('Currently not available')
        # Check if this specific item is unavailable
        sku_idx = page_text.index(sku)
        nearby_text = page_text[[sku_idx - 200, 0].max..[sku_idx + 200, page_text.length - 1].min] if sku_idx
        if nearby_text&.include?('Currently not available')
          raise ScrapingError, "Product SKU #{sku} is currently not available"
        end
      end

      # Find the quantity input for THIS specific SKU.
      # CRITICAL: Never fall back to the first input — a fuzzy search may return
      # multiple products (e.g., SKU 95342 and 95324), and picking the wrong one
      # orders the wrong product.
      set_result = browser.evaluate(<<~JS)
        (function() {
          var sku = '#{sku}';
          var inputs = document.querySelectorAll('input[type=number]');
          if (inputs.length === 0) return { status: 'no_inputs' };

          // If there's exactly one input, verify the page actually contains our exact SKU
          // near that input before using it
          var targetInput = null;

          // Walk each input and find the one whose containing row/card has our EXACT SKU.
          // Use progressively broader parent selectors to find the product container.
          for (var i = 0; i < inputs.length; i++) {
            var el = inputs[i];
            // Walk up the DOM tree looking for a container that has our exact SKU
            var parent = el.parentElement;
            var depth = 0;
            while (parent && depth < 15) {
              var text = parent.innerText || '';
              // Check for exact SKU match using word boundary (not substring match).
              // This prevents SKU 95342 from matching a row containing only 95324.
              var skuPattern = new RegExp('(^|\\\\D)' + sku.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&') + '(\\\\D|$)');
              if (skuPattern.test(text)) {
                targetInput = inputs[i];
                break;
              }
              parent = parent.parentElement;
              depth++;
            }
            if (targetInput) break;
          }

          if (!targetInput) {
            return { status: 'no_match', inputCount: inputs.length };
          }

          var nativeSetter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value'
          ).set;
          nativeSetter.call(targetInput, '#{qty}');
          targetInput.dispatchEvent(new Event('input', { bubbles: true }));
          targetInput.dispatchEvent(new Event('change', { bubbles: true }));
          targetInput.dispatchEvent(new Event('blur', { bubbles: true }));
          return { status: 'set_qty' };
        })()
      JS

      if set_result.is_a?(Hash)
        case set_result['status']
        when 'no_inputs'
          raise ScrapingError, "No quantity input found for SKU #{sku}"
        when 'no_match'
          raise ScrapingError, "Could not match quantity input to SKU #{sku} (#{set_result['inputCount']} inputs on page, none matched)"
        end
      elsif set_result == 'no_inputs'
        raise ScrapingError, "No quantity input found for SKU #{sku}"
      end

      sleep 2

      # Verify cart total updated (should be > $0.00)
      cart_total = begin
        browser.evaluate(<<~JS)
          (function() {
            var buttons = document.querySelectorAll('button');
            for (var i = 0; i < buttons.length; i++) {
              var match = buttons[i].innerText.trim().match(/^\\$([\\d,.]+)$/);
              if (match) return parseFloat(match[1].replace(',', ''));
            }
            return 0;
          })()
        JS
      rescue StandardError
        0.0
      end

      logger.info "[WhatChefsWant] Cart total after adding SKU #{sku}: $#{cart_total}"
    end

    public

    def checkout(dry_run: false)
      logger.info "[WhatChefsWant] checkout starting (dry_run=#{dry_run})"

      # Reuse the browser from add_to_cart (cart doesn't persist across sessions)
      ensure_order_browser!

      begin
        ensure_on_order_page
        sleep 2

        # Check cart total before proceeding
        cart_total = get_cart_total
        raise ScrapingError, 'Cart is empty — no items to checkout' if cart_total <= 0

        logger.info "[WhatChefsWant] Cart total: $#{cart_total}, proceeding to review"

        # Click the cart total button (cdbutton with price) to navigate to review page.
        # Wait up to 10s for the button to appear (page may still be rendering after add_to_cart).
        click_result = 'not_found'
        5.times do |attempt|
          click_result = browser.evaluate(<<~JS)
            (function() {
              var btns = document.querySelectorAll('button.cdbutton, .cdbutton');
              for (var i = 0; i < btns.length; i++) {
                var text = btns[i].innerText.trim();
                if (text.match(/^\\$[\\d,.]+$/) && text !== '$0.00') {
                  btns[i].click();
                  return 'clicked';
                }
              }
              return 'not_found';
            })()
          JS
          break if click_result == 'clicked'

          logger.debug "[WhatChefsWant] Cart button not found, retry #{attempt + 1}..."
          sleep 2
        end

        raise ScrapingError, 'Cart total button not found — cart may be empty' if click_result == 'not_found'

        sleep 5

        # Wait for review page SPA render
        wait_for_spa_load(timeout: 10)
        sleep 2

        # Verify we're on the review page
        page_text = begin
          browser.evaluate("document.body ? document.body.innerText : ''")
        rescue StandardError
          ''
        end
        unless page_text.include?('Review Order') || page_text.include?('Submit Order')
          raise ScrapingError, 'Failed to navigate to order review page'
        end

        # Parse order details from the review page
        order_total = parse_review_total(page_text)
        delivery_info = parse_delivery_info(page_text)
        item_count = parse_item_count(page_text)

        logger.info "[WhatChefsWant] Review: #{item_count} items, total: $#{order_total}, delivery: #{delivery_info}"

        # DOM discovery logging for review page
        dom_info = browser.evaluate(<<~JS)
          (function() {
            return {
              url: window.location.href,
              buttons: Array.from(document.querySelectorAll('button'))
                .filter(function(b) { return b.offsetParent !== null; })
                .slice(0, 15)
                .map(function(b) { return { text: b.innerText.trim().substring(0, 50), classes: b.className.substring(0, 80) }; }),
              page_text_preview: document.body.innerText.substring(0, 500)
            };
          })()
        JS
        logger.info "[WhatChefsWant] Review page DOM: #{dom_info.inspect}"

        # Check for unavailable items
        has_unavailable = page_text.include?('Currently not available')
        logger.warn '[WhatChefsWant] Some items may be unavailable' if has_unavailable

        # ═══════════════════════════════════════════
        # ═══ SAFETY GATE — DRY RUN CHECK ══════════
        # ═══════════════════════════════════════════
        if dry_run
          logger.info "[WhatChefsWant] DRY RUN COMPLETE — stopping before Submit Order"
          logger.info "[WhatChefsWant] Would have placed order: total=$#{order_total}"

          return {
            confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
            total: order_total,
            delivery_date: delivery_info,
            dry_run: true,
            cart_items: [],
            checkout_summary: {
              total: order_total,
              delivery_date: delivery_info,
              item_count: item_count,
              has_unavailable_items: has_unavailable
            }
          }
        end

        # ═══ LIVE ORDER — Submit ══════════════════
        logger.warn '[WhatChefsWant] PLACING LIVE ORDER — clicking Submit Order'

        # Click "Submit Order" button
        submit_result = browser.evaluate(<<~JS)
          (function() {
            var buttons = document.querySelectorAll('button');
            for (var i = 0; i < buttons.length; i++) {
              if (buttons[i].innerText.trim() === 'Submit Order') {
                buttons[i].click();
                return 'submitted';
              }
            }
            return 'not_found';
          })()
        JS

        raise ScrapingError, 'Submit Order button not found on review page' if submit_result == 'not_found'

        logger.info '[WhatChefsWant] Order submitted, waiting for confirmation...'
        sleep 5

        # Check for confirmation or error
        post_submit_text = begin
          browser.evaluate("document.body ? document.body.innerText : ''")
        rescue StandardError
          ''
        end
        begin
          browser.current_url
        rescue StandardError
          ''
        end

        # Look for confirmation indicators
        confirmation_number = nil
        if post_submit_text.match?(/order.*(confirm|submitted|placed|received|#\d+)/i)
          conf_match = post_submit_text.match(/#(\d+)/) ||
                       post_submit_text.match(/order\s*(?:number|#|id)[:\s]*(\w+)/i)
          confirmation_number = conf_match[1] if conf_match
        end

        # Check for error messages
        if post_submit_text.match?(/error|failed|could not|unable/i) &&
           !post_submit_text.match?(/confirm|success|submitted/i)
          error_snippet = post_submit_text[0..500]
          raise ScrapingError, "Order submission may have failed: #{error_snippet.truncate(200)}"
        end

        logger.info "[WhatChefsWant] Order placed. Confirmation: #{confirmation_number || 'pending'}"

        {
          confirmation_number: confirmation_number,
          total: order_total,
          delivery_date: delivery_info
        }
      ensure
        close_order_browser!
      end
    end

    # Remove individual items from the draft by SKU.
    # Gets current draft items, filters out the target SKUs, and updates the draft.
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
          # Find price from nested product data
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

      # Update draft with only the remaining items
      if removed.any?
        api_client.update_draft(draft_id, delivery_date, keep_items)
        @last_wcw_sequence_id = nil # Reset sequence tracking
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

    # Scrape the order guide from What Chefs Want (Cut+Dry platform).
    # WCW has a single order guide at the /place-order URL.
    # Returns array with one list hash per the BaseScraper#scrape_lists contract.
    def scrape_supplier_lists
      logger.info '[WhatChefsWant] Scraping order guide'
      ensure_on_order_page
      sleep 3

      # Wait for the SPA to settle (it client-side redirects from /place-order
      # to /place-order/{ids}/quantities) and for the table to render
      wait_for_order_table

      # Cut+Dry uses virtual scroll — DOM elements are recycled as you scroll.
      # Only ~10-25 rows exist in the DOM at any time. We must extract visible
      # products DURING scrolling and accumulate them in a persistent JS object.
      products = scroll_and_extract_order_guide

      logger.info "[WhatChefsWant] Order guide: #{products.size} products after scroll-and-extract"

      list_url = begin
        browser.current_url
      rescue StandardError
        "#{PLATFORM_URL}/place-order"
      end

      items = (products || []).each_with_index.map do |p, idx|
        {
          sku: p['sku'],
          name: p['name'],
          price: p['price'].is_a?(Numeric) ? p['price'] : nil,
          pack_size: p['pack_size'].to_s.strip.presence,
          quantity: 1,
          in_stock: p['in_stock'] != false,
          position: idx + 1
        }
      end

      [{
        name: 'Order Guide',
        remote_id: 'order-guide',
        url: list_url,
        list_type: 'order_guide',
        items: items
      }]
    end

    protected

    def perform_login_steps
      welcome_url = credential.username
      if welcome_url.present? && welcome_url.start_with?('http')
        # Welcome URL auth — navigate and wait for SPA
        logger.info '[WhatChefsWant] perform_login_steps via welcome URL'
        navigate_to(welcome_url)
        wait_for_page_load
        wait_for_spa_load

        5.times do |_i|
          break if logged_in?

          sleep 3
        end
      else
        # Password-based login on Cut+Dry React SPA
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

    # Fill the Cut+Dry React SPA login form using native setters.
    # Inputs: text field for email/mobile, password field.
    def fill_cutanddry_login_form
      escaped_user = credential.username.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      escaped_pass = credential.password.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")

      browser.evaluate(<<~JS)
        (function() {
          var inputs = document.querySelectorAll('input');
          var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          for (var i = 0; i < inputs.length; i++) {
            var type = (inputs[i].type || '').toLowerCase();
            var placeholder = (inputs[i].placeholder || '').toLowerCase();
            if (type === 'password') {
              nativeSetter.call(inputs[i], '#{escaped_pass}');
              inputs[i].dispatchEvent(new Event('input', { bubbles: true }));
              inputs[i].dispatchEvent(new Event('change', { bubbles: true }));
            } else if (type === 'text' || type === 'email') {
              if (placeholder.includes('email') || placeholder.includes('mobile') || placeholder.includes('phone')) {
                nativeSetter.call(inputs[i], '#{escaped_user}');
                inputs[i].dispatchEvent(new Event('input', { bubbles: true }));
                inputs[i].dispatchEvent(new Event('change', { bubbles: true }));
              }
            }
          }
        })()
      JS
    end

    # Click the Sign In button on the Cut+Dry login page.
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

    private

    # Manage a persistent browser for the order flow (add_to_cart + checkout).
    # The Cut+Dry platform does NOT persist cart state across sessions,
    # so we keep a single browser alive between add_to_cart and checkout.
    def ensure_order_browser!
      return if @browser # Already have an open browser

      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'
      browser_opts = { timeout: 30, headless: headless_mode }

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

      logger.info "[WhatChefsWant] Starting order browser (headless=#{headless_mode})"
      @browser = Ferrum::Browser.new(**browser_opts)
      setup_network_interception(@browser)

      # Login
      perform_login_steps
      sleep 2
      unless logged_in?
        close_order_browser!
        raise AuthenticationError, 'Could not log in for ordering'
      end
      save_session
      extract_cookies_for_api
    end

    def close_order_browser!
      @browser&.quit
      @browser = nil
    rescue StandardError => e
      logger.debug "[WhatChefsWant] Error closing order browser: #{e.message}"
      @browser = nil
    end

    # Extract cookies from the browser after login and pass them to the API client.
    def extract_cookies_for_api
      return unless @browser

      browser_cookies = {}
      csrf_token = nil

      begin
        # Get all cookies from the browser
        @browser.cookies.all.each do |name, cookie|
          browser_cookies[name.to_s] = cookie.value.to_s
        end

        # Also check for CSRF token in cookies
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

    # ----------------------------------------------------------------
    # API-based cart operations
    # ----------------------------------------------------------------

    def add_to_cart_via_api(items, delivery_date: nil)
      logger.info "[WhatChefsWant] Adding #{items.size} items to cart via API"

      delivery_date_str = if delivery_date
                            delivery_date.is_a?(String) ? delivery_date : delivery_date.strftime('%Y-%m-%d')
                          end

      # Map SKUs to Cut+Dry product IDs
      # We need to search for each SKU to find the product_id
      added_items = []
      failed_items = []

      # Build product list by looking up each SKU
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
          logger.info "[WhatChefsWant] Resolved SKU #{item[:sku]} → product #{product_id}"
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

      # Create draft order with all items
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

    def add_to_cart_via_browser(items, delivery_date: nil)
      ensure_order_browser!
      ensure_on_order_page
      sleep 2

      added_items = []
      failed_items = []

      items.each do |item|
        begin
          add_single_item_to_cart(item)
          added_items << item
          logger.info "[WhatChefsWant] Added SKU #{item[:sku]} (qty: #{item[:quantity]})"
        rescue StandardError => e
          logger.warn "[WhatChefsWant] Failed to add SKU #{item[:sku]}: #{e.message}"
          failed_items << { sku: item[:sku], error: e.message, name: item[:name] }
        end

        rate_limit_delay
      end

      if failed_items.any? && added_items.empty?
        close_order_browser!
        raise ItemUnavailableError.new(
          "#{failed_items.count} item(s) could not be added",
          items: failed_items
        )
      end

      { added: added_items.count, failed: failed_items }
    end

    # Resolve a supplier SKU (item code) to a Cut+Dry product ID via search.
    def resolve_product_id(sku)
      result = api_client.search_products(sku.to_s, limit: 5)
      contextual = result&.dig('data', 'catalogProductsSearchRootQuery', 'contextualProducts') || []
      products = contextual.map { |cp| cp['canonicalProduct'] }.compact

      # Find exact SKU match
      match = products.find { |p| p['itemCode'].to_s == sku.to_s }
      match ||= products.first if products.size == 1

      match&.dig('id')
    end

    # Wait for the Cut+Dry React SPA to fully hydrate.
    # The page initially renders as just "Home" until React mounts and renders the full UI.
    def wait_for_spa_load(timeout: 15)
      start_time = Time.current
      loop do
        # Check if the SPA has rendered meaningful content
        ready = begin
          browser.evaluate(<<~JS)
            (function() {
              var body = document.body ? document.body.innerText : '';
              // SPA is loaded when there's more than just the title text
              if (body.trim().length > 50) return true;
              // Or if there are multiple nav/anchor elements (rendered UI)
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

    public

    # Override scrape_catalog to use hybrid category browsing + search.
    # Supports &on_batch for incremental DB writes — yields batches as each
    # category/search completes instead of accumulating everything in memory.
    def scrape_catalog(search_terms, max_per_term: 50, &on_batch)
      results = []

      with_browser do
        # Login if needed
        navigate_to(BASE_URL)

        if restore_session
          browser.refresh
          sleep 2
        end

        # Only login if session restore didn't work
        unless logged_in?
          welcome_url = credential.username
          if welcome_url.present? && welcome_url.start_with?('http')
            login_via_welcome_url(welcome_url)
          else
            login_via_credentials
          end
        end

        raise AuthenticationError, 'Could not log in for catalog import' unless logged_in?

        save_session

        # Phase 1: Browse categories for broad coverage
        logger.info "[WhatChefsWant] Phase 1: Browsing #{WCW_CATEGORIES.size} categories"
        WCW_CATEGORIES.each do |category|
          begin
            products = browse_category(category[:filter], max: max_per_term)
            products.each { |p| p[:category] ||= category[:name] }
            if on_batch
              on_batch.call(products)
            else
              results.concat(products)
            end
            logger.info "[WhatChefsWant] Category '#{category[:name]}': #{products.size} products"
          rescue StandardError => e
            logger.warn "[WhatChefsWant] Category browse failed for '#{category[:name]}': #{e.class}: #{e.message}"
          end
          rate_limit_delay
        end

        # Optimization: If categories yielded enough products, limit search phase
        category_target = 400
        search_phase_limit = nil
        if !on_batch && results.size >= category_target
          search_phase_limit = 10
          logger.info "[WhatChefsWant] Categories yielded #{results.size} products (target: #{category_target}). Limiting search phase to #{search_phase_limit} terms."
        else
          logger.info "[WhatChefsWant] Running full search phase."
        end

        # Phase 2: Search terms for items missed in categories
        terms_to_search = search_phase_limit ? search_terms.first(search_phase_limit) : search_terms
        logger.info "[WhatChefsWant] Phase 2: Searching with #{terms_to_search.size} terms"
        terms_to_search.each do |term|
          begin
            products = search_supplier_catalog(term, max: max_per_term)
            if on_batch
              on_batch.call(products)
            else
              results.concat(products)
            end
            logger.info "[WhatChefsWant] Search '#{term}': #{products.size} products"
          rescue StandardError => e
            logger.warn "[WhatChefsWant] Search failed for '#{term}': #{e.class}: #{e.message}"
          end
          rate_limit_delay
        end
      end

      # When streaming via on_batch, return empty array (caller already has the data)
      return [] if on_batch

      # De-duplicate by SKU
      deduped = results.uniq { |r| r[:supplier_sku] }
      logger.info "[WhatChefsWant] Total unique products: #{deduped.size} (from #{results.size} raw)"
      deduped
    end

    # Browse a category by clicking on the category filter
    def browse_category(category_filter, max: 50)
      ensure_on_order_page

      # Clear any existing search
      search_el = browser.at_css('#order_flow_search') || browser.at_css("input[placeholder*='Search']")
      if search_el
        search_el.click
        sleep 0.3
        browser.evaluate(<<~JS)
          (function() {
            var input = document.getElementById('order_flow_search') ||
                        document.querySelector("input[placeholder*='Search']");
            if (input) { input.focus(); input.select(); }
          })()
        JS
        sleep 0.2
        browser.keyboard.type([:control, 'a'])
        sleep 0.2
        browser.keyboard.type(:backspace)
        sleep 0.5
        browser.keyboard.type(:enter)
        sleep 2
      end

      # Try to find and click the category filter
      category_clicked = begin
        browser.evaluate(<<~JS)
          (function() {
            var targetFilter = '#{category_filter}';

            // Look for filter buttons by text content
            var buttons = document.querySelectorAll('button, [role="button"]');
            for (var btn of buttons) {
              var text = (btn.innerText || '').trim();
              if (text.toLowerCase().includes(targetFilter.toLowerCase())) {
                btn.click();
                return true;
              }
            }

            // Look for checkbox filters
            var checkboxes = document.querySelectorAll('input[type="checkbox"]');
            for (var cb of checkboxes) {
              var label = cb.parentElement;
              if (label && label.innerText.toLowerCase().includes(targetFilter.toLowerCase())) {
                cb.click();
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
        logger.info "[WhatChefsWant] Clicked category filter: #{category_filter}"
        sleep 3
      else
        logger.debug "[WhatChefsWant] Could not click category filter '#{category_filter}', using search fallback"
        perform_order_page_search(category_filter)
      end

      # Extract products from the page
      page_text = begin
        browser.evaluate("document.body ? document.body.innerText : ''")
      rescue StandardError
        ''
      end
      parse_catalog_results(page_text, max: max)
    end

    def search_supplier_catalog(term, max: 50)
      # The Cut+Dry platform uses an in-page search on the /place-order page.
      # Navigate there on first search, then reuse for subsequent searches.
      ensure_on_order_page

      logger.info "[WhatChefsWant] Searching for: #{term}"
      perform_order_page_search(term)

      # The catalog results appear as text in the page. DOM elements may be
      # inside an iframe or shadow DOM, so we parse from document.body.innerText.
      page_text = begin
        browser.evaluate("document.body ? document.body.innerText : ''")
      rescue StandardError
        ''
      end

      # Extract products from the "Catalog Results" section
      products = parse_catalog_results(page_text, max: max)
      logger.info "[WhatChefsWant] Found #{products.size} products for '#{term}'"

      products
    end

    # Search on the Cut+Dry order page using real keyboard events.
    # The React SPA ignores nativeSetter for subsequent searches — it only
    # responds to actual keyboard input events. So we:
    #   1. Click the input to focus it
    #   2. Select all + Backspace to clear previous search
    #   3. Type the new term via keyboard
    #   4. Press Enter via keyboard
    def perform_order_page_search(term)
      search_el = browser.at_css('#order_flow_search') || browser.at_css("input[placeholder*='Search']")
      raise ScrapingError, 'Search input not found on order page' unless search_el

      # Click and focus the input
      search_el.click
      sleep 0.3

      # Select all existing text and delete it
      browser.evaluate(<<~JS)
        (function() {
          var input = document.getElementById('order_flow_search') ||
                      document.querySelector("input[placeholder*='Search']");
          if (input) { input.focus(); input.select(); }
        })()
      JS
      sleep 0.2
      browser.keyboard.type([:control, 'a'])
      sleep 0.2
      browser.keyboard.type(:backspace)
      sleep 0.5

      # Type the search term using real keyboard events
      browser.keyboard.type(term)
      sleep 0.5

      # Submit with Enter
      browser.keyboard.type(:enter)
      sleep 4
    end

    def ensure_on_order_page
      current = begin
        browser.current_url
      rescue StandardError
        ''
      end
      return if current.include?('place-order')

      logger.info '[WhatChefsWant] Navigating to order page'
      navigate_to("#{PLATFORM_URL}/place-order")
      wait_for_spa_load(timeout: 10)
      sleep 2
    end

    # Parse product data from the page text output of Cut+Dry catalog search.
    # Format for each product block:
    #   Product Name
    #   Brand (optional)
    #   Pack Size | #ItemCode
    #   Unit Type (Case/Each/Pound)
    #   $Price
    #   Add to Cart
    def parse_catalog_results(text, max: 20)
      products = []

      # Only parse from "Catalog Results" section onwards
      catalog_section = text.split('Catalog Results').last
      return products unless catalog_section

      # Stop at "Don't Forget to Order" if present (recommended items section)
      catalog_section = catalog_section.split("Don't Forget to Order").first || catalog_section

      # Split by "Add to Cart" to get individual product blocks
      blocks = catalog_section.split('Add to Cart')

      blocks.first(max).each do |block|
        lines = block.strip.split("\n").map(&:strip).reject(&:blank?)
        next if lines.size < 3

        # Find the line with item code: contains "| #" pattern
        code_line_idx = lines.index { |l| l.include?('| #') || l.match?(/#\d{3,}/) }
        next unless code_line_idx

        code_line = lines[code_line_idx]
        # Extract item code from "2/5LB CS | #33354" or just "#33354"
        sku_match = code_line.match(/#(\d+)/)
        next unless sku_match

        sku = sku_match[1]

        # Product name is above the code line
        name = lines[0..([code_line_idx - 1, 0].max)].first
        next if name.blank? || name.length < 3

        # Brand might be the line between name and code
        brand = nil
        brand = lines[code_line_idx - 1] if code_line_idx >= 2

        # Pack size from the code line (everything before | #)
        pack_size = code_line.split('|').first&.strip

        # Find price line: starts with $ or contains $/
        price_line = lines.find { |l| l.match?(/\$[\d,.]+/) }
        price = nil
        if price_line
          # Prefer case/CS price when dual pricing is shown
          # e.g. "$6.85/lb ($43.85/cs)" → take $43.85 (the case price)
          # The case price is what the user actually pays when ordering
          cs_match = price_line.match(/\$([\d,.]+)\s*\/?\s*(?:cs|case)/i)
          if cs_match
            price = cs_match[1].gsub(',', '').to_f
          else
            # No case price found — take the first price (may be per-unit or flat)
            price_match = price_line.match(/\$([\d,.]+)/)
            price = price_match[1].gsub(',', '').to_f if price_match
          end
        end

        # Find unit type (Case, Each, Pound)
        unit_line = lines.find { |l| l.match?(/^(Case|Each|Pound|Gallon|Bag|Box)$/i) }
        unit = unit_line&.strip

        # Check if product is available
        in_stock = !block.include?('Currently not available')

        # Full name with brand
        full_name = brand.present? ? "#{name} #{brand}".truncate(255) : name.truncate(255)

        products << {
          supplier_sku: sku,
          supplier_name: full_name,
          current_price: price,
          pack_size: [pack_size, unit].compact.join(' - '),
          supplier_url: nil,
          in_stock: in_stock,
          category: nil,
          scraped_at: Time.current
        }
      rescue StandardError => e
        logger.debug "[WhatChefsWant] Failed to parse product block: #{e.message}"
      end

      products
    end

    def scrape_product(sku)
      navigate_to("#{PLATFORM_URL}/products/#{sku}")

      return nil unless browser.at_css('.product-page, .product-detail')

      price_text = extract_text('.price, .product-price, .current-price')
      raw_price = extract_price(price_text)
      pack_size = extract_text('.pack-size, .product-unit')

      # Detect per-unit pricing from text (e.g., "$12.50/LB", "$3.99 / OZ")
      price_unit = nil
      if price_text =~ /\/\s*(LB|OZ|EA|GAL|KG|CT)\b/i
        price_unit = $1.downcase
      end

      # Convert per-unit prices to estimated case totals
      effective_price = UnitParser.estimated_total(raw_price, price_unit, pack_size)

      {
        supplier_sku: sku,
        supplier_name: extract_text('.product-title, .product-name, h1'),
        current_price: effective_price,
        pack_size: pack_size,
        price_unit: price_unit,
        in_stock: browser.at_css('.out-of-stock, .unavailable, .sold-out').nil?,
        scraped_at: Time.current
      }
    end

    # Scroll down the order page to load all products (Cut+Dry lazy-loads).
    # Counts actual table rows with 5+ cells (matching extraction logic) to
    # reliably detect when new products have loaded.
    # Wait for the order guide table to render after SPA navigation.
    # Cut+Dry redirects from /place-order to /place-order/{ids}/quantities.
    def wait_for_order_table
      10.times do
        has_table = browser.evaluate('document.querySelectorAll("table tr").length > 0')
        break if has_table

        sleep 1
      end
      sleep 2 # Extra settle time for React rendering
    end

    # Scroll through the virtual-scroll order guide, extracting products as we go.
    # Cut+Dry recycles DOM rows — only ~10-25 exist at any time. We accumulate
    # products in a window-level JS object that persists across scroll positions.
    def scroll_and_extract_order_guide
      # The extraction JS is inlined in each evaluate call so it survives
      # any SPA micro-navigations that might clear window globals.
      extract_js = <<~'JSTEMPLATE'
        (function() {
          if (!window.__wcwProducts) window.__wcwProducts = {};
          var rows = document.querySelectorAll('table tr');
          var newCount = 0;
          for (var i = 0; i < rows.length; i++) {
            var cells = rows[i].querySelectorAll('td');
            if (cells.length < 5) continue;

            var sku = (cells[1] ? cells[1].innerText.trim() : '').replace(/\D/g, '');
            if (!sku) {
              var dataFor = cells[0].querySelector('[data-for^="product-card-"]');
              if (dataFor) {
                var m = dataFor.getAttribute('data-for').match(/product-card-(\d+)/);
                if (m) sku = m[1];
              }
            }
            if (!sku || window.__wcwProducts[sku]) continue;

            var nameEl = cells[0].querySelector('[data-tip="View Product Details"]');
            if (!nameEl) nameEl = cells[0].querySelector('div > div > span > div');
            var name = nameEl ? nameEl.innerText.trim() : '';
            if (!name) {
              var lines = (cells[0].innerText || '').trim().split('\n');
              for (var j = 0; j < lines.length; j++) {
                if (lines[j].trim().length > 3) { name = lines[j].trim(); break; }
              }
            }
            if (!name) continue;

            var unit = cells[2] ? cells[2].innerText.trim() : '';
            var packText = (cells[0].innerText || '').trim();
            var packMatch = packText.match(/(\d+[x\/]\d+[\s]*\w+(?:\s+\w+)?|\d+\s*(?:LB|OZ|CS|EA|CT|GAL|COUNT)\b[^\n]*)/i);
            var packSize = packMatch ? packMatch[1].trim() : '';

            var priceText = cells[4] ? cells[4].innerText.trim() : '';
            var price = null;
            var priceUnit = null;

            // 1. Case/CS price (total for the pack)
            var csMatch = priceText.match(/\$(\d+[\d,]*\.\d{2})\s*\/?\s*(?:CS|case)/i);
            if (csMatch) {
              price = parseFloat(csMatch[1].replace(',', ''));
            }

            // 2. Per-unit price (e.g., "$12.50/LB", "$3.99/OZ", "$5.00/EA")
            if (!price) {
              var perUnitMatch = priceText.match(/\$(\d+[\d,]*\.\d{2})\s*\/\s*(LB|OZ|EA|GAL|KG|CT)\b/i);
              if (perUnitMatch) {
                price = parseFloat(perUnitMatch[1].replace(',', ''));
                priceUnit = perUnitMatch[2].toLowerCase();
              }
            }

            // 3. Fallback: any dollar amount
            if (!price) {
              var pm = priceText.match(/\$(\d+[\d,]*\.\d{2})/);
              if (pm) price = parseFloat(pm[1].replace(',', ''));
            }

            window.__wcwProducts[sku] = {
              sku: sku,
              name: name.substring(0, 255),
              price: price,
              price_unit: priceUnit,
              pack_size: [packSize, unit].filter(Boolean).join(' - '),
              in_stock: true
            };
            newCount++;
          }
          return { total: Object.keys(window.__wcwProducts).length, newInRound: newCount };
        })()
      JSTEMPLATE

      # Initial extraction
      result = browser.evaluate(extract_js)
      logger.info "[WhatChefsWant] Initial extraction: #{result['total']} products"

      # Scroll and extract
      # WCW's React/Cut+Dry SPA needs more render time per scroll than Angular-based
      # sites. 0.3s was too fast — rows hadn't rendered before the next extraction,
      # causing false "stale" detection and early exit (15 items instead of 136).
      stale_rounds = 0
      max_scrolls = 80

      max_scrolls.times do |round|
        browser.evaluate('window.scrollBy(0, Math.round(window.innerHeight * 0.75))')
        sleep 0.8

        result = browser.evaluate(extract_js)

        if result['newInRound'] == 0
          stale_rounds += 1
          break if stale_rounds >= 3
        else
          stale_rounds = 0
        end

        if (round + 1) % 10 == 0
          logger.info "[WhatChefsWant] Scroll round #{round + 1}: #{result['total']} total products accumulated"
        end
      end

      # Collect all accumulated products
      products = browser.evaluate('Object.values(window.__wcwProducts)')
      logger.info "[WhatChefsWant] Scroll-and-extract complete: #{products.size} products"
      products
    rescue StandardError => e
      logger.error "[WhatChefsWant] scroll_and_extract_order_guide failed: #{e.message}"
      []
    end

    # Parse order guide items from page text. Similar to parse_catalog_results
    # but without the "Catalog Results" header requirement since we're on
    # the order guide page directly.
    def parse_order_guide_items(text)
      products = []

      # Split by "Add to Cart" to get individual product blocks
      blocks = text.split('Add to Cart')

      blocks.each_with_index do |block, idx|
        lines = block.strip.split("\n").map(&:strip).reject(&:blank?)
        next if lines.size < 2

        # Find the line with item code
        code_line_idx = lines.index { |l| l.include?('| #') || l.match?(/#\d{3,}/) }
        next unless code_line_idx

        code_line = lines[code_line_idx]
        sku_match = code_line.match(/#(\d+)/)
        next unless sku_match

        sku = sku_match[1]
        name = lines[0..([code_line_idx - 1, 0].max)].first
        next if name.blank? || name.length < 3

        brand = code_line_idx >= 2 ? lines[code_line_idx - 1] : nil
        pack_size = code_line.split('|').first&.strip

        price_line = lines.find { |l| l.match?(/\$[\d,.]+/) }
        price = nil
        if price_line
          price_match = price_line.match(/\$([\d,.]+)/)
          price = price_match[1].gsub(',', '').to_f if price_match
        end

        unit_line = lines.find { |l| l.match?(/^(Case|Each|Pound|Gallon|Bag|Box)$/i) }
        unit = unit_line&.strip

        in_stock = !block.include?('Currently not available')
        full_name = brand.present? ? "#{name} #{brand}".truncate(255) : name.truncate(255)

        products << {
          sku: sku,
          name: full_name,
          price: price,
          pack_size: [pack_size, unit].compact.join(' - '),
          quantity: 1,
          in_stock: in_stock,
          position: idx + 1
        }
      rescue StandardError => e
        logger.debug "[WhatChefsWant] Failed to parse order guide item: #{e.message}"
      end

      products
    end

    # Get the current cart total from the cart button on the order page.
    # The cart button is a cdbutton with btn-primary showing just "$XX.XX".
    def get_cart_total
      browser.evaluate(<<~JS)
        (function() {
          // Target the specific cart total button (cdbutton with price)
          var btns = document.querySelectorAll('button.cdbutton, .cdbutton');
          for (var i = 0; i < btns.length; i++) {
            var text = btns[i].innerText.trim();
            var match = text.match(/^\\$([\\d,.]+)$/);
            if (match) return parseFloat(match[1].replace(',', ''));
          }
          return 0;
        })()
      JS
    rescue StandardError
      0.0
    end

    # Parse the order total from the review page text
    def parse_review_total(text)
      # Look for "Total:\t$XX.XX" pattern
      match = text.match(/Total:\s*\$?([\d,.]+)/)
      match ? match[1].gsub(',', '').to_f : nil
    end

    # Parse delivery info from the review page text
    def parse_delivery_info(text)
      # Look for "Delivery Date:" followed by a date or "Order Cutoff:"
      return unless text.match?(/Delivery Date:\s*\n?\s*(.+)/)

      date_match = text.match(/Order Cutoff:\s*\n?\s*(.+)/)
      date_match ? date_match[1].strip : nil
    end

    # Parse item count from the review page text
    def parse_item_count(text)
      match = text.match(/Total Line Items:\s*(\d+)/)
      match ? match[1].to_i : 0
    end
  end
end
