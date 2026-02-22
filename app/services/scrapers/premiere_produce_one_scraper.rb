module Scrapers
  class PremiereProduceOneScraper < BaseScraper
    BASE_URL = 'https://premierproduceone.pepr.app'.freeze
    LOGIN_URL = "#{BASE_URL}/".freeze
    ORDER_MINIMUM = 0.00
    CHECKOUT_LIVE = false # HARD SAFETY GATE: set to true ONLY when ready for live PPO orders

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
          if added_items.empty?
            # ALL items failed — nothing in the cart, can't proceed
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

        { added: added_items.count, failed: failed_items }
      end
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
      search_input.focus
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
      sleep 1.5

      # Verify the + click actually registered: after adding, the modal should show
      # a quantity display (e.g., "1") and the + button changes to "Increase quantity".
      # Also check if a "Decrease quantity" button appeared (indicates item was added).
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

      logger.info "[PremiereProduceOne] Add verification for SKU #{item[:sku]}: #{add_verified.inspect}"

      # If add didn't register, try clicking + again
      unless add_verified&.dig('verified')
        logger.warn "[PremiereProduceOne] Add not verified for SKU #{item[:sku]}, retrying + click"
        retry_clicked = click_modal_add_button_ppo(item[:sku])
        if retry_clicked
          sleep 1.5
          logger.info "[PremiereProduceOne] Retry + click for SKU #{item[:sku]} completed"
        else
          logger.warn "[PremiereProduceOne] Retry + click failed for SKU #{item[:sku]}"
        end
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
      sleep 1 # Brief pause before next item
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
            var body = document.body ? document.body.innerText : '';
            var skuPattern = new RegExp('(?:Case|Each|Piece|Pack|Bag|Box|Unit)\\\\s*[•·]\\\\s*' + targetSku);
            if (skuPattern.test(body)) {
              return { already_open: true };
            }

            function isNavText(text) {
              var lower = text.toLowerCase();
              for (var w of navSkipWords) {
                if (lower === w || (lower.length < 30 && lower.includes(w))) return true;
              }
              return false;
            }

            // Strategy 1: Find the SMALLEST element matching the product name
            if (productName) {
              var nameUpper = productName.toUpperCase();
              var nameWords = nameUpper.split(/\\s+/);
              var shortName = nameWords.length > 3 ? nameWords.slice(0, Math.ceil(nameWords.length * 0.6)).join(' ') : nameUpper;

              var allElements = document.querySelectorAll('div, span, p, li, a');
              var nameMatches = [];

              for (var el of allElements) {
                if (el.offsetParent === null) continue;
                var text = (el.textContent || '').trim();
                var textUpper = text.toUpperCase();
                if (text.length < 5 || text.length > 200) continue;
                if (isNavText(text)) continue;

                var matches = textUpper.includes(nameUpper) ||
                              nameUpper.includes(textUpper) ||
                              textUpper.includes(shortName) ||
                              shortName.includes(textUpper);

                if (matches) {
                  var rect = el.getBoundingClientRect();
                  if (rect.width > 30 && rect.height > 10) {
                    nameMatches.push({
                      text: text,
                      textLen: text.length,
                      x: rect.left + rect.width / 2,
                      y: rect.top + rect.height / 2,
                      width: rect.width,
                      height: rect.height
                    });
                  }
                }
              }

              // Sort by text length (shortest first = most specific element)
              nameMatches.sort(function(a, b) { return a.textLen - b.textLen; });

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
              var rawSkuPattern = new RegExp('[•·]\\\\s*' + targetSku);
              // And look for dialog content specifically
              var dialogs = document.querySelectorAll('[role="dialog"], [aria-modal="true"]');
              var dialogText = '';
              for (var d of dialogs) { dialogText += (d.textContent || '') + ' '; }
              return {
                has_sku_text: skuPattern.test(body),
                has_raw_sku: rawSkuPattern.test(body),
                has_sku_in_dialog: dialogText.includes(targetSku),
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

    def checkout(dry_run: false)
      effective_dry_run = dry_run || !CHECKOUT_LIVE
      logger.info "[PremiereProduceOne] checkout starting (dry_run=#{effective_dry_run}, CHECKOUT_LIVE=#{CHECKOUT_LIVE})"

      with_browser do
        # Step 1: Session restore + login (replicate from add_to_cart)
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          wait_for_react_render(timeout: 15)
        end

        unless logged_in?
          logger.info '[PremiereProduceOne] Not logged in, performing login'
          perform_login_steps

          if two_fa_page?
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

          save_session
        end

        # Step 2: Navigate to cart page
        navigate_to_cart_page_ppo

        # Step 3: Extract cart data
        cart_data = extract_cart_data_ppo
        logger.info "[PremiereProduceOne] Cart: #{cart_data[:item_count]} items, subtotal=#{cart_data[:subtotal]}"

        # Step 4: Validate cart — Pepper may not expose item count via inputs,
        # so also check subtotal as an indicator the cart has items.
        if cart_data[:item_count] == 0 && cart_data[:subtotal] == 0
          raise ScrapingError, 'Cart is empty'
        end
        if cart_data[:item_count] == 0 && cart_data[:subtotal] > 0
          logger.warn "[PremiereProduceOne] item_count=0 but subtotal=$#{cart_data[:subtotal]} — Pepper may not expose qty inputs. Proceeding."
        end

        # Step 5: Check for unavailable items
        if cart_data[:unavailable_items].any?
          raise ItemUnavailableError.new(
            "#{cart_data[:unavailable_items].count} item(s) are unavailable",
            items: cart_data[:unavailable_items]
          )
        end

        # Step 6: Navigate to checkout/review page
        proceed_to_checkout_page_ppo

        # Step 7: Extract checkout data
        checkout_data = extract_checkout_data_ppo
        logger.info "[PremiereProduceOne] Checkout: total=#{checkout_data[:total]}, delivery=#{checkout_data[:delivery_date]}"

        # ═══════════════════════════════════════════
        # ═══ SAFETY GATE — DRY RUN CHECK ══════════
        # ═══════════════════════════════════════════
        if effective_dry_run
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

        # Step 8: LIVE ORDER — Click final submit
        logger.warn "[PremiereProduceOne] PLACING LIVE ORDER — clicking submit"
        click_place_order_button_ppo

        # Step 9: Wait for confirmation
        confirmation = wait_for_order_confirmation_ppo

        logger.info "[PremiereProduceOne] Order placed: #{confirmation[:confirmation_number]}"
        confirmation
      end
    end

    def clear_cart
      logger.info '[PremiereProduceOne] Clearing cart...'

      with_browser do
        # Restore session
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          wait_for_react_render(timeout: 15)
        end

        unless logged_in?
          logger.warn '[PremiereProduceOne] Cannot clear cart: not logged in (2FA required)'
          return
        end

        # IMPORTANT: In Pepper, /cart shows the Order Guide (NOT the shopping cart).
        # The actual cart is a MODAL/PANEL opened by clicking the "View Order" button
        # (cart icon with $ total) in the top-right nav bar.
        # We must click that button via CDP mouse to open the cart panel.

        # First check if "View Order" button exists (indicates items in cart)
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

        if !view_order || !view_order['found']
          logger.info '[PremiereProduceOne] No "View Order" button found — cart appears empty'
          save_session
          return
        end

        logger.info "[PremiereProduceOne] Found View Order button: #{view_order['text'].inspect} at (#{view_order['x']}, #{view_order['y']})"

        # Click the View Order button to open the cart panel
        browser.mouse.click(x: view_order['x'].to_f, y: view_order['y'].to_f)
        sleep 2
        wait_for_react_render(timeout: 10)

        # Verify cart panel opened — should now have decrease/trash buttons
        page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
        logger.info "[PremiereProduceOne] Cart panel text (first 300): #{page_text[0..300]}"

        # Check if cart panel shows empty
        if page_text.match?(/cart is empty|no items|your cart is empty/i)
          logger.info '[PremiereProduceOne] Cart panel shows empty'
          save_session
          return
        end

        # Log what buttons are now available in the cart panel
        cart_buttons = browser.evaluate(<<~JS)
          (function() {
            var results = [];
            var buttons = document.querySelectorAll('button, [role="button"]');
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
        # Pepper (React Native Web) cart items have qty controls:
        #   - When qty > 1: "Decrease quantity" button (minus icon) + qty display + "Increase quantity" button
        #   - When qty = 1: trash/delete button (replaces the minus) + qty display + "Increase quantity" button
        # To remove an item: click decrease until qty=1, then click trash.
        #
        # CRITICAL: React Native Web Pressable components ignore el.click().
        # We MUST use Ferrum's browser.mouse.click(x:, y:) which sends real
        # CDP Input.dispatchMouseEvent — same pattern used in open_product_modal_ppo.
        #
        # SAFETY: We NEVER click "Increase quantity". We only click buttons whose
        # aria-label matches "Decrease quantity" or trash/remove/delete patterns.

        removed_count = 0
        total_clicks = 0
        max_total_clicks = 2000 # absolute safety limit
        stale_rounds = 0

        loop do
          break if total_clicks >= max_total_clicks

          # Scan ALL visible buttons for decrease/trash — return COORDINATES, not click in JS
          result = browser.evaluate(<<~JS)
            (function() {
              var buttons = document.querySelectorAll('button, [role="button"]');
              for (var btn of buttons) {
                if (btn.offsetParent === null) continue;
                var aria = (btn.getAttribute('aria-label') || '').toLowerCase();
                var btnText = (btn.textContent || '').trim().toLowerCase();

                // Match: "Decrease quantity" (the minus button) or trash/remove/delete
                if (aria.includes('decrease') || aria.includes('trash') ||
                    aria.includes('remove') || aria.includes('delete') ||
                    btnText === 'remove' || btnText === 'delete') {
                  btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                  var rect = btn.getBoundingClientRect();
                  return {
                    found: true, aria: aria, btnText: btnText,
                    x: rect.left + rect.width / 2,
                    y: rect.top + rect.height / 2
                  };
                }
              }
              return { found: false, reason: 'no decrease/trash buttons on page' };
            })()
          JS

          # No decrease/trash buttons left → cart is empty
          if result.nil? || !result['found']
            reason = result&.dig('reason') || 'unknown'

            # Maybe buttons haven't rendered yet — retry a few times
            stale_rounds += 1
            if stale_rounds >= 3
              logger.info "[PremiereProduceOne] No decrease/trash buttons found after #{stale_rounds} checks — cart should be empty (#{removed_count} items removed, #{total_clicks} clicks)"
              break
            end

            sleep 1
            wait_for_react_render(timeout: 5)
            next
          end

          stale_rounds = 0
          total_clicks += 1

          # Log progress
          aria = result['aria'] || ''
          is_trash = aria.include?('trash') || aria.include?('remove') || aria.include?('delete')

          if is_trash
            removed_count += 1
            logger.info "[PremiereProduceOne] Removed item #{removed_count} via trash at (#{result['x']}, #{result['y']}) (click ##{total_clicks})"
          elsif total_clicks <= 5 || total_clicks % 20 == 0
            logger.info "[PremiereProduceOne] Decreasing qty at (#{result['x']}, #{result['y']}) (click ##{total_clicks}, aria=#{aria})"
          end

          # CDP mouse click — the ONLY way to trigger React Native Web Pressable
          browser.mouse.click(x: result['x'].to_f, y: result['y'].to_f)

          # Brief pause for React to update the button state
          sleep 0.3

          # Handle any confirmation modal after trash click
          if is_trash
            sleep 0.5
            confirm_pepper_modal
            sleep 0.5
            wait_for_react_render(timeout: 5)
          end

          # Periodic longer wait for React to catch up
          if total_clicks % 50 == 0
            sleep 1
            wait_for_react_render(timeout: 5)
          end
        end

        logger.info "[PremiereProduceOne] Cart clearing complete: #{removed_count} items removed, #{total_clicks} total clicks"

        # Verify cart is empty
        sleep 2
        page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''

        # Check for the "Place order" button or any dollar amount — indicates items remain
        has_place_order = page_text.match?(/place order/i)
        has_price = page_text.match?(/\$\d+\.\d{2}/)

        if page_text.match?(/cart is empty|no items/i)
          logger.info '[PremiereProduceOne] Cart confirmed empty!'
        elsif has_place_order || has_price
          logger.warn "[PremiereProduceOne] Cart may still have items (place_order=#{has_place_order}, has_price=#{has_price})"
          logger.warn "[PremiereProduceOne] Cart text: #{page_text[0..200]}"
        else
          logger.info '[PremiereProduceOne] Cart appears cleared (no Place Order button or prices found)'
        end

        save_session
      end
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

    # ─── Checkout helper methods ───────────────────────────────────

    def navigate_to_cart_page_ppo
      # Try /cart first (Pepper platform standard)
      navigate_to("#{BASE_URL}/cart")
      sleep 3
      wait_for_react_render(timeout: 10)

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
        sleep 3
        wait_for_react_render(timeout: 10)
        page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
      end

      logger.info "[PremiereProduceOne] Cart page URL: #{browser.current_url rescue 'unknown'}"
      logger.info "[PremiereProduceOne] Cart page text (first 300): #{page_text[0..300]}"

      # Scroll to bottom to reveal sticky footer / submit button
      browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
      sleep 2

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
      cart_data = browser.evaluate(<<~JS)
        (function() {
          var result = { items: [], subtotal: 0, item_count: 0, unavailable: [] };
          var pageText = document.body ? document.body.innerText : '';

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

      logger.info "[PremiereProduceOne] Cart extraction: items=#{(cart_data['items'] || []).size}, subtotal=#{cart_data['subtotal']}, item_count=#{cart_data['item_count']}"

      {
        items: (cart_data['items'] || []).map { |i| { name: i['name'], sku: i['sku'], price: i['price'], quantity: i['quantity'] } },
        subtotal: cart_data['subtotal'] || 0,
        item_count: [cart_data['item_count'] || 0, (cart_data['items'] || []).size].max,
        unavailable_items: (cart_data['unavailable'] || []).map { |i| { name: i['name'], sku: i['sku'], message: 'Unavailable' } }
      }
    end

    def proceed_to_checkout_page_ppo
      # Pepper cart flow:
      # 1. /cart page shows items + a "View Order" button (shows as "$X.XX" with aria-label="View Order")
      # 2. Clicking "View Order" takes you to the order review/submit page
      # 3. Review page has "Submit Order" button
      #
      # The "View Order" button is at the TOP of the page (sticky header at y=0).
      # It has aria-label="View Order" and textContent like "$1,396.20".

      # Step 1: Look for the "View Order" button by aria-label (most reliable for Pepper)
      clicked = browser.evaluate(<<~JS)
        (function() {
          var elements = document.querySelectorAll('button, [role="button"], a');

          // Priority 1: aria-label based detection (Pepper uses "View Order")
          var ariaTargets = ['view order', 'review order', 'checkout', 'view cart', 'order summary'];
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var aria = (el.getAttribute('aria-label') || '').toLowerCase();
            if (!aria) continue;
            for (var target of ariaTargets) {
              if (aria.includes(target)) {
                el.click();
                return {
                  clicked: true,
                  text: (el.textContent || '').trim().substring(0, 60),
                  aria: aria,
                  method: 'aria-label'
                };
              }
            }
          }

          // Priority 2: textContent match for submit/checkout/review
          var exclude = /search|clear|close|cancel|filter|back|sign|log|add note/i;
          var textTargets = ['submit order', 'place order', 'checkout', 'proceed to checkout',
                             'review order', 'view order', 'continue to checkout', 'submit', 'complete order'];
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var text = (el.textContent || '').trim().toLowerCase();
            if (text.length > 60 || text.length === 0) continue;
            if (exclude.test(text)) continue;
            for (var target of textTargets) {
              if (text.includes(target)) {
                el.click();
                return { clicked: true, text: text, tag: el.tagName, method: 'textContent-match' };
              }
            }
          }

          // Priority 3: Button containing $ amount with SVG (the cart total button)
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var text = (el.textContent || '').trim();
            var hasSvg = !!el.querySelector('svg');
            if (text.match(/^\\$[\\d,]+\\.\\d{2}$/) && hasSvg) {
              el.click();
              return { clicked: true, text: text, method: 'price-button-with-svg' };
            }
          }

          // Priority 4: href-based links
          var links = document.querySelectorAll('a[href*="checkout"], a[href*="review"], a[href*="order"]');
          for (var link of links) {
            if (link.offsetParent !== null) {
              var text = (link.textContent || '').trim().toLowerCase();
              if (!exclude.test(text) && text.length < 40) {
                link.click();
                return { clicked: true, text: text, href: link.href, method: 'href-match' };
              }
            }
          }

          return { clicked: false };
        })()
      JS

      if clicked && clicked['clicked']
        logger.info "[PremiereProduceOne] Clicked checkout/review button: #{clicked.inspect}"
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

      sleep 5
      wait_for_react_render(timeout: 15)

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
      sleep 2

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

          // Delivery date extraction
          var datePatterns = [
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
        total: checkout_data['total'] || 0,
        delivery_date: checkout_data['delivery_date'],
        summary_text: checkout_data['summary_text'],
        buttons: checkout_data['buttons'] || []
      }
    end

    def click_place_order_button_ppo
      # Scroll to bottom where the submit button lives
      browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
      sleep 2

      clicked = browser.evaluate(<<~JS)
        (function() {
          var exclude = /search|clear|close|cancel|filter|back|sign|log|add note/i;
          var targets = ['place order', 'submit order', 'complete order', 'confirm order', 'submit'];
          var elements = document.querySelectorAll('button, [role="button"]');

          for (var el of elements) {
            if (el.offsetParent === null) continue;
            // Use textContent for React Native Web
            var text = (el.textContent || el.innerText || '').trim().toLowerCase();
            if (text.length > 60 || text.length === 0) continue;
            if (exclude.test(text)) continue;
            for (var target of targets) {
              if (text.includes(target)) {
                el.scrollIntoView({ behavior: 'instant', block: 'center' });
                el.click();
                return { clicked: true, text: text };
              }
            }
          }

          // Check fixed/sticky footer
          var fixedEls = Array.from(document.querySelectorAll('*')).filter(function(el) {
            var style = window.getComputedStyle(el);
            return (style.position === 'fixed' || style.position === 'sticky') && el.offsetParent !== null;
          });
          for (var fixedEl of fixedEls) {
            var btns = fixedEl.querySelectorAll('button, [role="button"]');
            for (var btn of btns) {
              var text = (btn.textContent || '').trim().toLowerCase();
              if (text.length > 0 && text.length < 60 && !exclude.test(text)) {
                for (var target of targets) {
                  if (text.includes(target)) {
                    btn.click();
                    return { clicked: true, text: text, method: 'fixed-footer' };
                  }
                }
              }
            }
          }

          return { clicked: false };
        })()
      JS

      raise ScrapingError, 'Could not find place order button' unless clicked && clicked['clicked']

      logger.info "[PremiereProduceOne] Clicked place order: #{clicked.inspect}"
    end

    def wait_for_order_confirmation_ppo
      start_time = Time.current
      timeout = 30

      loop do
        page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''

        if page_text.match?(/confirmation|order\s*(?:placed|submitted|received)|thank\s*you|order\s*#/i)
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

        if page_text.match?(/error|failed|could not|unable to/i) && !page_text.match?(/confirmation|success|submitted/i)
          raise ScrapingError, "Checkout failed: #{page_text[0..300]}"
        end

        raise ScrapingError, 'Checkout confirmation timeout (30s)' if Time.current - start_time > timeout

        sleep 1
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
