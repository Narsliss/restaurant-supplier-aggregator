module Scrapers
  class PremiereProduceOneScraper < BaseScraper
    BASE_URL = 'https://premierproduceone.pepr.app'.freeze
    LOGIN_URL = "#{BASE_URL}/".freeze
    ORDER_MINIMUM = 0.00

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

            if logged_in?
              save_session
              credential.mark_active!
              save_trusted_device
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
      # Use longer TTL for PPO (24h instead of default 1h) since 2FA is expensive
      return false unless credential.last_login_at.present? && credential.last_login_at > 24.hours.ago

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
    # Returns true if session is alive (and extends last_login_at), false if expired.
    # Does NOT trigger 2FA or attempt login — just checks if the saved session works.
    def soft_refresh
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
    # PPO needs the full login flow (with 2FA code polling) to get past the
    # verification page.
    def scrape_catalog(search_terms, max_per_term: 50)
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
    # full login with 2FA, so we can't rely on BaseScraper's version which
    # calls perform_login_steps but doesn't handle 2FA code polling.
    def scrape_lists
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

    def scrape_prices(product_skus)
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

    def add_to_cart(items, delivery_date: nil)
      @target_delivery_date = delivery_date

      with_browser do
        # PPO requires full login with 2FA - restore session first
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          wait_for_react_render(timeout: 15)
        end

        unless logged_in?
          # Full login with 2FA handling
          perform_login_steps

          if two_fa_page?
            # Need verification code
            code = wait_for_user_code(attempt: 1, resent: false)
            raise AuthenticationError, 'Verification timed out' unless code

            type_code_and_submit(code)
            sleep 5
            wait_for_page_load

            raise AuthenticationError, 'Login failed after 2FA' unless logged_in?

            save_session
            credential.mark_active!
            mark_2fa_request_verified!
            TwoFactorChannel.broadcast_to(credential.user, { type: 'code_result', success: true })

          end

          save_session unless logged_in?
        end

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
          raise ItemUnavailableError.new(
            "#{failed_items.count} item(s) could not be added",
            items: failed_items
          )
        end

        { added: added_items.count }
      end
    end

    private

    def add_single_item_to_cart(item)
      # PPO is a React SPA - search for the product using the search input
      search_input = browser.at_css("input[placeholder='Search']")

      unless search_input
        # Navigate to catalog to get search input
        ensure_catalog_page_loaded
        search_input = browser.at_css("input[placeholder='Search']")
      end

      raise ScrapingError, 'Search input not found' unless search_input

      # Search for the product by SKU
      search_input.focus
      set_react_input_value(search_input, item[:sku].to_s)
      sleep 3 # Wait for React to filter results

      # PPO displays products in a list with format:
      # Product Name | Brand: X | Pack Size: Y | Case • SKU | [+] button
      # Find the product row containing our SKU and click its "+" button
      quantity_to_add = item[:quantity].to_i
      quantity_to_add = 1 if quantity_to_add < 1

      # Click the "Increase quantity" button for the matching product
      # Each click adds 1 to the quantity, so we click multiple times for quantity > 1
      quantity_to_add.times do |i|
        clicked = browser.evaluate(<<~JS)
          (function() {
            // Find all elements that contain "Case • SKU" pattern
            var allElements = document.querySelectorAll('*');
            var targetSku = '#{item[:sku]}';

            for (var el of allElements) {
              // Skip elements with many children (we want leaf/near-leaf nodes)
              if (el.children.length > 5) continue;

              var text = el.innerText || '';
              // Match "Case • SKU" or "Each • SKU" or "Piece • SKU"
              var match = text.match(/(?:Case|Each|Piece)\\s*[•·]\\s*(\\d+)/);
              if (match && match[1] === targetSku) {
                // Found the SKU! Now find the "+" button in the same product row
                // Walk up to find the product container, then find the button
                var container = el;
                for (var j = 0; j < 10 && container; j++) {
                  container = container.parentElement;
                  if (!container) break;

                  // Look for button with "+" or aria-label containing "increase" or "add"
                  var buttons = container.querySelectorAll('button');
                  for (var btn of buttons) {
                    var btnText = (btn.innerText || '').trim();
                    var ariaLabel = (btn.getAttribute('aria-label') || '').toLowerCase();

                    // PPO uses a "+" button or "Increase quantity" button
                    if (btnText === '+' ||
                        btnText === '' && btn.querySelector('svg') || // Icon button
                        ariaLabel.includes('increase') ||
                        ariaLabel.includes('add')) {
                      btn.click();
                      return { found: true, clicked: true, sku: targetSku };
                    }
                  }
                }
              }
            }

            // Fallback: If there's only one product visible (from search), click the first "+" button
            var plusButtons = document.querySelectorAll('button');
            for (var btn of plusButtons) {
              var ariaLabel = (btn.getAttribute('aria-label') || '').toLowerCase();
              if (ariaLabel.includes('increase quantity')) {
                btn.click();
                return { found: true, clicked: true, method: 'fallback' };
              }
            }

            return { found: false };
          })()
        JS

        unless clicked && clicked['clicked']
          raise ScrapingError, "Product not found or could not click add button for SKU #{item[:sku]}" if i == 0

          logger.warn "[PremiereProduceOne] Could only add #{i} of #{quantity_to_add} for SKU #{item[:sku]}"
          break

        end

        # Small delay between clicks for quantity > 1
        sleep 0.3 if i < quantity_to_add - 1
      end

      logger.info "[PremiereProduceOne] Clicked + button #{quantity_to_add} time(s) for SKU #{item[:sku]}"

      # Wait for cart confirmation
      wait_for_cart_confirmation
    end

    def wait_for_cart_confirmation
      wait_for_any_selector(
        '.cart-added',
        '.success-message',
        '.cart-updated',
        '.cart-notification',
        '.toast',
        "[class*='success']",
        timeout: 5
      )
      sleep 1
    rescue ScrapingError
      logger.debug '[PremiereProduceOne] No confirmation modal, checking cart state'
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

    def checkout
      with_browser do
        navigate_to("#{BASE_URL}/cart")
        wait_for_selector('.cart-container, .shopping-cart, .cart-page')

        validate_cart_before_checkout

        unavailable = detect_unavailable_items_in_cart
        if unavailable.any?
          raise ItemUnavailableError.new(
            "#{unavailable.count} item(s) are unavailable",
            items: unavailable
          )
        end

        click(".checkout, .btn-checkout, [data-action='checkout']")
        wait_for_selector('.checkout-page, .order-review')

        click(".place-order, .btn-submit-order, [data-action='place-order']")
        wait_for_confirmation_or_error

        {
          confirmation_number: extract_text('.order-id, .confirmation-number, .order-ref'),
          total: extract_price(extract_text('.total, .order-total')),
          delivery_date: extract_text('.delivery-date, .expected-delivery')
        }
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

    # Set a value on a React controlled input using the native HTMLInputElement
    # value setter. React overrides the input's value property with its own getter/setter,
    # so setting .value directly doesn't trigger React's onChange. By calling the NATIVE
    # setter from HTMLInputElement.prototype, we bypass React's override, then dispatch
    # the proper events so React picks up the change.
    def set_react_input_value(input_node, value)
      escaped = value.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")

      js = <<~JS
        (function(el) {
          // Clear first
          var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          nativeSetter.call(el, '');
          el.dispatchEvent(new Event('input', { bubbles: true }));

          // Set the actual value
          nativeSetter.call(el, '#{escaped}');

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

    # Navigate to the Order Guide page by clicking the sidebar link.
    def navigate_to_order_guide
      logger.info '[PremiereProduceOne] Navigating to Order Guide'
      clicked = browser.evaluate(<<~JS)
        (function() {
          // Look for "Order Guide" in sidebar links/buttons
          var els = document.querySelectorAll('a, button, [role="button"], [class*="nav"] *');
          for (var i = 0; i < els.length; i++) {
            var text = (els[i].innerText || '').trim().toLowerCase();
            if (text === 'order guide' || text.includes('order guide')) {
              els[i].click();
              return true;
            }
          }
          return false;
        })()
      JS

      if clicked
        sleep 3
        wait_for_react_render(timeout: 10)
      else
        logger.warn '[PremiereProduceOne] Could not find Order Guide link in sidebar'
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
      browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('button');
          for (var i = 0; i < buttons.length; i++) {
            if (buttons[i].innerText.trim() === 'All') {
              buttons[i].click();
              return;
            }
          }
        })()
      JS
      sleep 2

      # Scroll to load all products
      previous_count = 0
      stale_rounds = 0
      20.times do
        browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
        sleep 2

        current_count = begin
          browser.evaluate(<<~JS)
            (document.body.innerText.match(/(?:Case|Each|Piece)\\s*[•·]\\s*\\d{3,}/g) || []).length
          JS
        rescue StandardError
          0
        end

        if current_count <= previous_count
          stale_rounds += 1
          break if stale_rounds >= 3
        else
          stale_rounds = 0
        end
        previous_count = current_count
      end

      # Parse products using the same logic as extract_products_from_catalog
      page_text = begin
        browser.evaluate("document.body ? document.body.innerText : ''")
      rescue StandardError
        ''
      end

      lines = page_text.split("\n").map(&:strip).reject(&:blank?)
      products = []

      lines.each_with_index do |line, i|
        sku_match = line.match(/^(?:Case|Each|Piece)\s*[•·]\s*(\d{3,})$/)
        next unless sku_match

        sku = sku_match[1]
        name = nil
        price = nil
        pack_size = nil
        brand = nil
        unit = line.match(/^(Case|Each|Piece)/)[1]

        (i - 1).downto([i - 6, 0].max) do |j|
          prev_line = lines[j]
          if prev_line.match?(/^(All|BAKERY|BEVERAGE|DAIRY|FFV|FOODSERVICE|PANTRY|PRODUCE|PROTEIN|SPECIALTY|Sort:)/)
            next
          end
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

        full_name = brand.present? ? "#{name} #{brand}".truncate(255) : name.truncate(255)

        products << {
          sku: sku,
          name: full_name,
          price: price,
          pack_size: pack_size.present? ? "#{unit} - #{pack_size}" : unit,
          quantity: 1,
          in_stock: true,
          position: products.size + 1
        }
      end

      products
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
  end
end
