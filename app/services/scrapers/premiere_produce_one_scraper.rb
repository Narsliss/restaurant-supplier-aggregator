module Scrapers
  class PremiereProduceOneScraper < BaseScraper
    BASE_URL = "https://premierproduceone.pepr.app".freeze
    LOGIN_URL = "#{BASE_URL}/".freeze
    ORDER_MINIMUM = 0.00

    # PPO uses passwordless auth: email → code → logged in.
    # Because the verification page is a React SPA with no URL change and no cookies,
    # we MUST keep the browser alive while waiting for the user's code.
    # This method is designed to run inside a Sidekiq job.
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
            click_button_by_text("resend code")
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
              logger.info "[PremiereProduceOne] Verification successful — logged in!"
              TwoFactorChannel.broadcast_to(credential.user, { type: "code_result", success: true })
              return true
            end

            # Still on code page — code was likely expired or invalid
            body_text = browser.evaluate("document.body?.innerText?.substring(0, 2000)") rescue ""
            logger.warn "[PremiereProduceOne] Code attempt #{attempt} failed. Page: #{body_text[0..200]}"

            if body_text.match?(/maximum.*attempts|too many.*attempts|try again.*minutes|rate.?limit/i)
              rate_msg = body_text.scan(/maximum.*?minutes\.?|too many.*?minutes\.?|try again.*?minutes\.?/i).first
              error_msg = rate_msg&.strip || "Too many login attempts. Please wait and try again."
              credential.mark_failed!(error_msg)
              raise AuthenticationError, error_msg
            end

            # Notify user the code didn't work, but we can retry
            if attempt < max_code_attempts && two_fa_page?
              mark_2fa_request_failed!
              TwoFactorChannel.broadcast_to(
                credential.user,
                { type: "code_result", success: false, error: "Code expired or invalid. A new code is being sent — please enter the new code.", can_retry: true }
              )
            end
          else
            credential.mark_failed!("Verification timed out. No code was entered.")
            raise AuthenticationError, "Verification timed out"
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
            { type: "code_result", success: false, error: error_msg, can_retry: false }
          )
          raise AuthenticationError, error_msg
        end
      end
    end

    # Not used for PPO — the login method handles code entry inline.
    # Kept for interface compatibility with TwoFactorChannel.
    def login_with_code(code)
      { success: false, error: "Use the inline verification form instead. Click Validate to start a new login." }
    end

    # Override save_session to also capture localStorage.
    # PPO's Pepper React SPA stores auth tokens in localStorage, not just cookies.
    # Without localStorage, cookie-only restore results in an unauthenticated React state.
    def save_session
      cookies = browser.cookies.all.transform_values(&:to_h)

      # Capture localStorage (contains Pepper auth tokens)
      local_storage = browser.evaluate(<<~JS) rescue {}
        (function() {
          var data = {};
          for (var i = 0; i < localStorage.length; i++) {
            var key = localStorage.key(i);
            data[key] = localStorage.getItem(key);
          }
          return data;
        })()
      JS

      session_payload = {
        cookies: cookies,
        local_storage: local_storage
      }.to_json

      credential.update!(
        session_data: session_payload,
        last_login_at: Time.current,
        status: "active"
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
        if data.key?("cookies")
          cookies = data["cookies"]
          local_storage = data["local_storage"] || {}
        else
          # Legacy format: entire session_data is cookies
          cookies = data
          local_storage = {}
        end

        # Restore cookies
        cookies.each do |_name, cookie|
          next unless cookie.is_a?(Hash) && cookie["name"].present? && cookie["value"].present?

          params = {
            name: cookie["name"].to_s,
            value: cookie["value"].to_s,
            domain: cookie["domain"].to_s,
            path: cookie["path"].present? ? cookie["path"].to_s : "/"
          }
          params[:secure] = !!cookie["secure"] unless cookie["secure"].nil?
          params[:httponly] = !!cookie["httponly"] unless cookie["httponly"].nil?
          if cookie["expires"].is_a?(Numeric) && cookie["expires"] > 0
            params[:expires] = cookie["expires"].to_i
          end

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
      return true if browser.at_css(".user-menu, .account-dropdown, .logged-in, [data-user-logged-in], .my-account, .account-nav").present?

      # Definitely NOT logged in if we're on the verification code page
      return false if two_fa_page?

      # PPO-specific: check for buttons/links that only appear when logged in.
      # "Log out" is in the footer/menu and won't appear in the first 3000 chars of body text
      # because PPO shows dozens of product listings first.
      has_logout = browser.evaluate("!!document.querySelector('button') && Array.from(document.querySelectorAll('button')).some(function(b) { return b.innerText.trim().toLowerCase() === 'log out'; })") rescue false
      return true if has_logout

      body_text = browser.evaluate("document.body?.innerText?.substring(0, 3000)") rescue ""

      # Definitely NOT logged in if we're on the landing page
      return false if body_text.match?(/become a customer/i) && body_text.match?(/explore catalog/i) && !body_text.match?(/order guide|add to cart|my orders/i)

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
                click_button_by_text("resend code")
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
                  logger.info "[PremiereProduceOne] Import login: verified!"
                  TwoFactorChannel.broadcast_to(credential.user, { type: "code_result", success: true })
                  break
                end

                if attempt < max_code_attempts && two_fa_page?
                  mark_2fa_request_failed!
                  TwoFactorChannel.broadcast_to(
                    credential.user,
                    { type: "code_result", success: false, error: "Code expired or invalid. A new code is being sent.", can_retry: true }
                  )
                end
              else
                credential.mark_failed!("Verification timed out during import. No code was entered.")
                raise AuthenticationError, "Verification timed out during catalog import"
              end
            end
          end

          unless logged_in?
            credential.mark_failed!("Could not log in for catalog import")
            raise AuthenticationError, "Could not log in for catalog import"
          end

          save_session
        end

        # Ensure we're on the catalog page with the search input visible.
        # When logged in, PPO shows the catalog directly. If not, click "Explore catalog".
        ensure_catalog_page_loaded

        # Now scrape the catalog
        search_terms.each do |term|
          begin
            products = search_supplier_catalog(term, max: max_per_term)
            results.concat(products)
            logger.info "[Scraper] Found #{products.size} products for '#{term}' at #{credential.supplier.name}"
          rescue ScrapingError => e
            logger.warn "[Scraper] Catalog search failed for '#{term}': #{e.message}"
          rescue => e
            logger.warn "[Scraper] Unexpected error searching '#{term}': #{e.class}: #{e.message}"
          end

          rate_limit_delay
        end
      end

      # De-duplicate by SKU
      results.uniq { |r| r[:supplier_sku] }
    end

    def scrape_prices(product_skus)
      results = []

      with_browser do
        login unless logged_in?

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
            if code
              type_code_and_submit(code)
              sleep 5
              wait_for_page_load

              if logged_in?
                save_session
                credential.mark_active!
                mark_2fa_request_verified!
                TwoFactorChannel.broadcast_to(credential.user, { type: "code_result", success: true })
              else
                raise AuthenticationError, "Login failed after 2FA"
              end
            else
              raise AuthenticationError, "Verification timed out"
            end
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
          rescue => e
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

      unless search_input
        raise ScrapingError, "Search input not found"
      end

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

        unless clicked && clicked["clicked"]
          if i == 0
            raise ScrapingError, "Product not found or could not click add button for SKU #{item[:sku]}"
          else
            logger.warn "[PremiereProduceOne] Could only add #{i} of #{quantity_to_add} for SKU #{item[:sku]}"
            break
          end
        end

        # Small delay between clicks for quantity > 1
        sleep 0.3 if i < quantity_to_add - 1
      end

      logger.info "[PremiereProduceOne] Clicked + button #{quantity_to_add} time(s) for SKU #{item[:sku]}"

      # Wait for cart confirmation
      wait_for_cart_confirmation
    end

    def click_add_to_cart_button
      browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('button, [role="button"]');
          for (var btn of buttons) {
            var text = btn.innerText?.trim().toLowerCase();
            var ariaLabel = (btn.getAttribute('aria-label') || '').toLowerCase();
            if (text === '+' ||
                ariaLabel.includes('increase quantity') ||
                ariaLabel.includes('add to cart') ||
                text === 'add to cart' ||
                text.includes('add to cart')) {
              btn.click();
              return true;
            }
          }
          return false;
        })()
      JS
    end

    def wait_for_cart_confirmation
      begin
        wait_for_any_selector(
          ".cart-added",
          ".success-message",
          ".cart-updated",
          ".cart-notification",
          ".toast",
          "[class*='success']",
          timeout: 5
        )
        sleep 1
      rescue ScrapingError
        logger.debug "[PremiereProduceOne] No confirmation modal, checking cart state"
        sleep 1
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

    def checkout
      with_browser do
        navigate_to("#{BASE_URL}/cart")
        wait_for_selector(".cart-container, .shopping-cart, .cart-page")

        validate_cart_before_checkout

        unavailable = detect_unavailable_items_in_cart
        if unavailable.any?
          raise ItemUnavailableError.new(
            "#{unavailable.count} item(s) are unavailable",
            items: unavailable
          )
        end

        click(".checkout, .btn-checkout, [data-action='checkout']")
        wait_for_selector(".checkout-page, .order-review")

        click(".place-order, .btn-submit-order, [data-action='place-order']")
        wait_for_confirmation_or_error

        {
          confirmation_number: extract_text(".order-id, .confirmation-number, .order-ref"),
          total: extract_price(extract_text(".total, .order-total")),
          delivery_date: extract_text(".delivery-date, .expected-delivery")
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
      click_button_by_text("sign in")
      sleep 2

      # Step 2: Switch to email tab (PPO defaults to phone number)
      browser.evaluate('(function() { var tabs = document.querySelectorAll("[aria-selected]"); for (var i = 0; i < tabs.length; i++) { if (tabs[i].getAttribute("aria-selected") === "false") { tabs[i].click(); return true; } } return false; })()') rescue nil
      sleep 1

      # Step 3: Enter email in the email input (using React-compatible setter)
      email_input = browser.at_css("input[type='email']")
      if email_input
        email_input.focus
        set_react_input_value(email_input, credential.username)
      else
        logger.warn "[PremiereProduceOne] Email input not found on login page"
        raise AuthenticationError, "Could not find email input on login page"
      end

      sleep 1

      # Step 4: Click Continue to submit email and trigger verification code
      click_button_by_text("continue")
      sleep 3
      wait_for_page_load

      # Check for rate limiting
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 2000)") rescue ""
      if body_text.match?(/maximum.*attempts|too many.*attempts|try again.*minutes|rate.?limit/i)
        rate_msg = body_text.scan(/maximum.*?minutes\.?|too many.*?minutes\.?|try again.*?minutes\.?/i).first
        error_msg = rate_msg&.strip || "Too many login attempts. Please wait and try again."
        credential.mark_failed!(error_msg)
        raise AuthenticationError, error_msg
      end
    end

    # Set a value on a React controlled input using the native HTMLInputElement
    # value setter. React overrides the input's value property with its own getter/setter,
    # so setting .value directly doesn't trigger React's onChange. By calling the NATIVE
    # setter from HTMLInputElement.prototype, we bypass React's override, then dispatch
    # the proper events so React picks up the change.
    def set_react_input_value(input_node, value)
      escaped = value.gsub("\\", "\\\\\\\\").gsub("'", "\\\\'")

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
    rescue => e
      logger.warn "[PremiereProduceOne] React setter failed (#{e.message}), falling back to character-by-character typing"
      # Fallback: type character by character which generates real keyboard events
      begin
        input_node.focus
        # Triple-click to select all, then delete
        input_node.evaluate("this.select()")
        browser.keyboard.type(:Backspace)
        sleep 0.2
        # Type each character individually to trigger React key events
        value.each_char do |char|
          browser.keyboard.type(char)
          sleep 0.05
        end
      rescue => e2
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
        body_text = browser.evaluate("document.body?.innerText?.substring(0, 2000)") rescue ""
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
        logger.info "[PremiereProduceOne] Catalog page already loaded (search input found)"
        return
      end

      # Try clicking "Explore catalog" button (visible when not logged in or on landing)
      clicked = click_button_by_text("explore catalog")
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
        click_button_by_text("explore catalog")
        sleep 5
      end

      logger.info "[PremiereProduceOne] Catalog page ready (search input: #{browser.at_css("input[placeholder='Search']").present?})"
    end

    # Create a 2FA request in the DB and poll for the user's code.
    # The browser stays open on the verification page while we wait.
    # Returns the code string when the user submits it, or nil on timeout.
    def wait_for_user_code(attempt: 1, resent: false)
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 1000)") rescue ""
      prompt = body_text.scan(/your code.*?\./i).first || "A verification code has been sent to your email."
      prompt = "NEW CODE SENT: #{prompt} (previous code expired)" if resent

      # Create the 2FA request record
      request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        request_type: "login",
        two_fa_type: "email",
        prompt_message: prompt,
        status: "pending",
        expires_at: 3.minutes.from_now
      )

      credential.update!(two_fa_enabled: true, two_fa_type: "email")

      # Broadcast to ActionCable (may not be received, but try)
      TwoFactorChannel.broadcast_to(
        credential.user,
        {
          type: "two_fa_required",
          request_id: request.id,
          session_token: request.session_token,
          supplier_name: credential.supplier.name,
          two_fa_type: "email",
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
          logger.warn "[PremiereProduceOne] Timed out waiting for code"
          return nil
        end

        request.reload

        case request.status
        when "submitted"
          # User submitted a code — return it
          logger.info "[PremiereProduceOne] Code received from user"
          return request.code_submitted
        when "cancelled"
          logger.info "[PremiereProduceOne] User cancelled 2FA"
          return nil
        when "failed", "expired"
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
        credential.mark_failed!("Could not find verification code input")
        raise AuthenticationError, "Could not find verification code input"
      end

      logger.info "[PremiereProduceOne] Typing verification code into input"

      # Type character-by-character (generates real key events React responds to)
      begin
        code_input.focus
        sleep 0.2
        browser.keyboard.type([:control, "a"])
        sleep 0.1
        browser.keyboard.type(:Backspace)
        sleep 0.2
        code.to_s.each_char do |char|
          browser.keyboard.type(char)
          sleep 0.05
        end
        actual = code_input.evaluate("this.value") rescue "unknown"
        logger.info "[PremiereProduceOne] Input value after typing: '#{actual}'"

        # If typing didn't stick, use React native setter
        if actual != code.to_s
          logger.warn "[PremiereProduceOne] Typing gave '#{actual}', using nativeInputValueSetter"
          set_react_input_value(code_input, code)
        end
      rescue => e
        logger.warn "[PremiereProduceOne] Typing failed: #{e.message}, using nativeInputValueSetter"
        set_react_input_value(code_input, code)
      end

      sleep 1

      # Click the LAST Continue button (PPO SPA may have multiple in the DOM)
      continue_clicked = click_last_button_by_text("continue")
      logger.info "[PremiereProduceOne] Continue clicked: #{continue_clicked}"

      unless continue_clicked
        # Fallback: press Enter
        begin
          code_input.focus
          browser.keyboard.type(:Enter)
          logger.info "[PremiereProduceOne] Pressed Enter as fallback"
        rescue => e
          logger.warn "[PremiereProduceOne] Enter fallback failed: #{e.message}"
        end
      end
    end

    # Helper to mark the latest submitted 2FA request as verified
    def mark_2fa_request_verified!
      Supplier2faRequest.where(supplier_credential: credential, status: "submitted")
        .order(created_at: :desc).first&.mark_verified!
    end

    # Helper to mark the latest submitted 2FA request as failed
    def mark_2fa_request_failed!
      Supplier2faRequest.where(supplier_credential: credential, status: "submitted")
        .order(created_at: :desc).first&.mark_failed!
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
        logger.warn "[PremiereProduceOne] Search input not found"
        return []
      end

      # Clear and type the search term
      search_input.focus
      sleep 0.3
      set_react_input_value(search_input, term)
      sleep 1.5 # Wait for React to filter results

      # DOM probe: scan all elements by innerText (not textContent) to handle
      # React's split-text-node rendering. Also search globally for $ prices.
      dom_probe = browser.evaluate(<<~JS) rescue nil
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

      if dom_probe
        probe = JSON.parse(dom_probe) rescue {}
        logger.info "[PremiereProduceOne] DOM probe URL: #{probe['url']}"
        logger.info "[PremiereProduceOne] DOM probe $ leaf nodes: #{probe['dollarElements']&.inspect}"
        logger.info "[PremiereProduceOne] DOM probe $ innerText: #{probe['dollarInnerText']&.inspect}"
        if probe["found"]
          logger.info "[PremiereProduceOne] DOM probe SKU found! ancestors: #{probe['ancestors']&.map { |a| "#{a['tag']}(#{a['textLen']}ch,$=#{a['hasDollar']})" }&.join(' > ')}"
          logger.info "[PremiereProduceOne] DOM probe card text: #{probe['cardText']&.gsub("\n", ' | ')&.truncate(500)}"
          html = probe["cardHtml"] || ""
          if html.include?("$")
            price_html = html.scan(/.{0,80}\$[\d,.]+.{0,40}/)
            logger.info "[PremiereProduceOne] DOM probe price HTML: #{price_html.first(3).inspect}"
          else
            logger.info "[PremiereProduceOne] DOM probe: NO $ in card HTML"
          end
        else
          logger.warn "[PremiereProduceOne] DOM probe: no SKU element found via innerText scan"
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

      parsed = JSON.parse(products_json) rescue {}
      items = parsed["products"] || []
      debug = parsed["debug"] || []

      items_with_price = items.count { |i| i["price"].present? }
      logger.info "[PremiereProduceOne] Parsed #{items.size} products for '#{term}' (#{items_with_price} with prices)"
      debug.each do |d|
        logger.info "[PremiereProduceOne] DEBUG product: sku=#{d['sku']} name=#{d['name']} price=#{d['price']} lines=#{d['lines'].inspect}"
      end

      items.map do |item|
        {
          supplier_sku: item["sku"],
          supplier_name: item["name"].to_s.truncate(255),
          current_price: item["price"],
          pack_size: item["pack_size"],
          supplier_url: "#{BASE_URL}/products/#{item["sku"]}",
          in_stock: item["in_stock"] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    rescue => e
      logger.warn "[PremiereProduceOne] search_supplier_catalog error for '#{term}': #{e.message}"
      []
    end

    def scrape_product(sku)
      navigate_to("#{BASE_URL}/products/#{sku}")

      return nil unless browser.at_css(".product-page, .product-detail")

      {
        supplier_sku: sku,
        supplier_name: extract_text(".product-title, .product-name, h1"),
        current_price: extract_price(extract_text(".price, .product-price, .current-price")),
        pack_size: extract_text(".pack-size, .product-unit"),
        in_stock: browser.at_css(".out-of-stock, .unavailable, .sold-out").nil?,
        scraped_at: Time.current
      }
    end

    def detect_unavailable_items_in_cart
      unavailable = []

      browser.css(".cart-item, .cart-product").each do |item|
        if item.at_css(".out-of-stock, .not-available")
          unavailable << {
            sku: item.at_css("[data-sku], [data-product]")&.attribute("data-sku"),
            name: item.at_css(".item-name, .product-title")&.text&.strip,
            message: item.at_css(".availability-msg")&.text&.strip
          }
        end
      end

      unavailable
    end

    def validate_cart_before_checkout
      detect_error_conditions

      if browser.at_css(".empty-cart, .cart-empty, .no-items")
        raise ScrapingError, "Cart is empty"
      end
    end

    def wait_for_confirmation_or_error
      start_time = Time.current
      timeout = 30

      loop do
        return true if browser.at_css(".order-confirmation, .success, .thank-you-page")

        error_msg = browser.at_css(".error-message, .checkout-error, .alert-danger")&.text&.strip
        if error_msg
          raise ScrapingError, "Checkout failed: #{error_msg}"
        end

        raise ScrapingError, "Checkout timeout" if Time.current - start_time > timeout
        sleep 0.5
      end
    end

    def two_fa_page?
      return true if browser.at_css("input[placeholder='Code']")

      body_text = browser.evaluate("document.body?.innerText?.substring(0, 3000)") rescue ""
      return true if body_text.include?("Verification code")
      return true if body_text.match?(/code.*been sent|enter.*code|verification.*code/i)
      return true if body_text.match?(/we.?(?:sent|texted|emailed).*code/i)
      return true if body_text.match?(/check your (?:phone|email|text)/i)

      code_selectors = [
        "input[name*='code']",
        "input[name*='verification']",
        "input[name*='otp']",
        "input[autocomplete='one-time-code']",
        ".verification-code-input",
        ".otp-input"
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
        ".verification-code-input input",
        ".otp-input input",
        "#verificationCode"
      ]

      specific_selectors.each do |selector|
        el = browser.at_css(selector)
        return el if el
      end

      browser.css("input[type='text'], input[type='tel'], input[type='number']").each do |input|
        placeholder = input.evaluate("this.placeholder || ''") rescue ""
        next if placeholder.match?(/email|password|search|phone/i)
        return input if placeholder.match?(/code|otp|verify|token/i)
      end

      browser.at_css("input[type='text']")
    end

    # Click a button by its visible text (case-insensitive exact match).
    # Clicks the FIRST matching button.
    def click_button_by_text(text)
      js = "(function() { var btns = document.querySelectorAll('button, [role=\"button\"]'); for (var i = 0; i < btns.length; i++) { if (btns[i].innerText.trim().toLowerCase() === '#{text.downcase}') { btns[i].click(); return true; } } return false; })()"
      result = browser.evaluate(js) rescue false
      unless result
        logger.debug "[PremiereProduceOne] Button '#{text}' not found"
      end
      result
    end

    # Click the LAST button matching the given text.
    # Useful in React SPAs where previous views may still be in the DOM.
    def click_last_button_by_text(text)
      js = "(function() { var btns = document.querySelectorAll('button, [role=\"button\"]'); var last = null; for (var i = 0; i < btns.length; i++) { if (btns[i].innerText.trim().toLowerCase() === '#{text.downcase}') { last = btns[i]; } } if (last) { last.click(); return true; } return false; })()"
      result = browser.evaluate(js) rescue false
      unless result
        logger.debug "[PremiereProduceOne] Button '#{text}' (last) not found"
      end
      result
    end

    def save_trusted_device
      remember_selectors = [
        "input[name*='remember']",
        "input[name*='trust']",
        "#rememberDevice",
        ".trust-device input[type='checkbox']",
        "input[name*='dont_ask']",
        "label[for*='remember'] input",
        "label[for*='trust'] input"
      ]

      remember_selectors.each do |selector|
        checkbox = browser.at_css(selector)
        if checkbox
          begin
            checked = checkbox.evaluate("this.checked") rescue false
            unless checked
              checkbox.evaluate("this.click()")
              logger.info "[PremiereProduceOne] Checked 'remember device' checkbox"
            end
          rescue => e
            logger.debug "[PremiereProduceOne] Could not check remember device: #{e.message}"
          end
          break
        end
      end

      button_selectors = [
        "button[class*='trust']",
        "button[class*='remember']",
        "a[class*='trust']",
        "[data-action*='trust']"
      ]

      button_selectors.each do |selector|
        btn = browser.at_css(selector)
        if btn
          begin
            btn.evaluate("this.click()")
            logger.info "[PremiereProduceOne] Clicked 'trust device' button"
          rescue => e
            logger.debug "[PremiereProduceOne] Could not click trust button: #{e.message}"
          end
          break
        end
      end
    rescue => e
      logger.debug "[PremiereProduceOne] save_trusted_device error: #{e.message}"
    end
  end
end
