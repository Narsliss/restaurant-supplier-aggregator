module Scrapers
  class ChefsWarehouseScraper < BaseScraper
    BASE_URL = "https://www.chefswarehouse.com".freeze
    ORDER_URL = "https://order.chefswarehouse.com".freeze
    ORDER_MINIMUM = 200.00

    # Broad selectors — the site is a JS SPA with dynamically generated IDs
    # The login form uses type=text for email (not type=email) and has uid-* IDs
    EMAIL_SELECTORS = [
      "#email", "#username", "#loginEmail", "#userEmail",
      "input[name='email']", "input[name='username']", "input[name='loginId']",
      "input[type='email']",
      # CW uses dynamic uid-* IDs, so we need to find input by context
      "input[id^='uid-'][type='text']",
      "input[placeholder*='email' i]",
      "input[placeholder*='username' i]", "input[aria-label*='email' i]"
    ].freeze

    PASSWORD_SELECTORS = [
      "#password", "#loginPassword", "#userPassword",
      "input[name='password']", "input[type='password']",
      "input[id^='uid-'][type='password']",
      "input[placeholder*='password' i]", "input[aria-label*='password' i]"
    ].freeze

    SUBMIT_SELECTORS = [
      ".btn-sign-in",
      "button.btn-sign-in",
      "button[type='submit'].btn-secondary",
      ".login-btn", ".sign-in-button", ".btn-login", ".login-button",
      "button[data-testid*='login' i]", "button[data-testid*='sign' i]",
      # CW has multiple submit buttons - look for Sign In text
      "button[type='submit']"
    ].freeze

    LOGGED_IN_SELECTORS = [
      ".account-menu", ".user-nav", ".my-account-link", ".account-dropdown",
      ".user-menu", ".logged-in", ".user-greeting",
      "[data-testid='account']", "[data-testid='user-menu']",
      "a[href*='my-account']", "a[href*='dashboard']",
      "a[href*='logout']", "a[href*='sign-out']", "button[aria-label*='account' i]",
      ".header-account", "#account-menu", "#user-nav"
    ].freeze

    def login
      with_browser do
        logger.info "[ChefsWarehouse] Starting login for #{credential.username}"

        # Determine the best login URL
        login_url = credential.supplier.login_url.presence || "#{BASE_URL}/login"
        logger.info "[ChefsWarehouse] Using login URL: #{login_url}"

        # Try restoring session first
        if restore_session
          navigate_to(BASE_URL)
          sleep 2 # Allow SPA to render
          if logged_in?
            logger.info "[ChefsWarehouse] Restored session successfully"
            return true
          end
          logger.info "[ChefsWarehouse] Session restore failed, proceeding with fresh login"
        end

        # Navigate to login page
        navigate_to(login_url)
        sleep 3 # Extra wait for SPA rendering
        logger.info "[ChefsWarehouse] On login page: #{browser.current_url}"

        # Check if we got redirected
        if browser.current_url != login_url
          logger.info "[ChefsWarehouse] Redirected to: #{browser.current_url}"
        end

        # Use JavaScript to find and fill the login form
        # CW has multiple forms/inputs on the page, we need to find the login-specific ones
        # The login form has: text input (email), password input, and "Sign In" button
        login_result = browser.evaluate(<<~JS)
          (function() {
            var result = { found: false, email: null, password: null, button: null };

            // Find the password field first - there's usually only one
            var passwordInputs = document.querySelectorAll('input[type="password"]');
            var passwordField = null;
            for (var pw of passwordInputs) {
              if (pw.offsetParent !== null) {
                passwordField = pw;
                break;
              }
            }

            if (!passwordField) {
              return { found: false, error: 'No visible password field' };
            }

            // Find the email/username field - it's a text input near the password field
            // Look for text inputs that appear before the password field in DOM order
            var allInputs = document.querySelectorAll('input[type="text"], input[type="email"]');
            var emailField = null;

            // Strategy: find text input that's in the same form or container as password
            var passwordContainer = passwordField.closest('form') || passwordField.closest('div[class*="login"]') || passwordField.parentElement?.parentElement?.parentElement;

            if (passwordContainer) {
              var containerInputs = passwordContainer.querySelectorAll('input[type="text"], input[type="email"]');
              for (var inp of containerInputs) {
                if (inp.offsetParent !== null && inp !== passwordField) {
                  emailField = inp;
                  break;
                }
              }
            }

            // Fallback: just find the visible text input that comes before password
            if (!emailField) {
              for (var inp of allInputs) {
                if (inp.offsetParent !== null) {
                  emailField = inp;
                  break;
                }
              }
            }

            if (!emailField) {
              return { found: false, error: 'No visible email/text field' };
            }

            // Find the Sign In button - look for button with "Sign In" text near the form
            var submitButton = null;
            var buttons = document.querySelectorAll('button[type="submit"], button');
            for (var btn of buttons) {
              var text = (btn.innerText || '').trim().toLowerCase();
              if (text === 'sign in' && btn.offsetParent !== null) {
                submitButton = btn;
                break;
              }
            }

            // Store the element IDs or generate temp IDs for reference
            if (!emailField.id) emailField.id = 'cw-temp-email-' + Date.now();
            if (!passwordField.id) passwordField.id = 'cw-temp-password-' + Date.now();
            if (submitButton && !submitButton.id) submitButton.id = 'cw-temp-submit-' + Date.now();

            return {
              found: true,
              emailId: emailField.id,
              passwordId: passwordField.id,
              submitId: submitButton ? submitButton.id : null,
              emailType: emailField.type,
              debug: {
                emailPlaceholder: emailField.placeholder,
                containerClass: passwordContainer?.className?.substring(0, 50)
              }
            };
          })()
        JS

        unless login_result && login_result["found"]
          dump = capture_page_diagnostics
          error_detail = login_result&.dig("error") || "unknown"
          raise AuthenticationError, "Login form not found (#{error_detail}). #{dump}"
        end

        logger.info "[ChefsWarehouse] Found login form: email=##{login_result['emailId']}, password=##{login_result['passwordId']}, submit=##{login_result['submitId']}"

        # Fill credentials using Ferrum's native CDP keyboard input
        # Vue 3 v-model only responds to real keyboard events from Chrome DevTools Protocol,
        # not synthetic JS events or nativeSetter tricks
        email_id = login_result["emailId"]
        password_id = login_result["passwordId"]
        submit_id = login_result["submitId"]

        # Get Ferrum element references via their discovered IDs
        email_el = browser.at_css("##{email_id}")
        password_el = browser.at_css("##{password_id}")

        unless email_el && password_el
          raise AuthenticationError, "Could not get element references for login fields"
        end

        # Fill email field using real keyboard input
        logger.info "[ChefsWarehouse] Typing username into email field"
        begin
          email_el.click
          sleep 0.2
          email_el.focus
          email_el.type(credential.username, :clear)
        rescue Ferrum::CoordinatesNotFoundError => e
          logger.debug "[ChefsWarehouse] Click failed for email, scrolling into view: #{e.message}"
          email_el.evaluate("this.scrollIntoView({ block: 'center' })")
          sleep 0.3
          email_el.click
          email_el.type(credential.username, :clear)
        end
        sleep 0.5

        # Fill password field using real keyboard input
        logger.info "[ChefsWarehouse] Typing password into password field"
        begin
          password_el.click
          sleep 0.2
          password_el.focus
          password_el.type(credential.password, :clear)
        rescue Ferrum::CoordinatesNotFoundError => e
          logger.debug "[ChefsWarehouse] Click failed for password, scrolling into view: #{e.message}"
          password_el.evaluate("this.scrollIntoView({ block: 'center' })")
          sleep 0.3
          password_el.click
          password_el.type(credential.password, :clear)
        end
        sleep 0.5

        logger.info "[ChefsWarehouse] Credentials entered, clicking submit"

        # Click submit button using Ferrum element click (real mouse event via CDP)
        if submit_id
          submit_el = browser.at_css("##{submit_id}")
          if submit_el
            begin
              submit_el.click
            rescue Ferrum::CoordinatesNotFoundError => e
              logger.debug "[ChefsWarehouse] Submit click failed, scrolling: #{e.message}"
              submit_el.evaluate("this.scrollIntoView({ block: 'center' })")
              sleep 0.3
              submit_el.click
            end
          else
            # Fallback: press Enter on password field
            browser.keyboard.type(:Enter)
          end
        else
          # No submit button found, press Enter
          browser.keyboard.type(:Enter)
        end

        sleep 2

        # If still on login page after click, try pressing Enter as fallback
        still_on_login = browser.current_url.to_s.include?("/login") rescue false
        if still_on_login
          logger.info "[ChefsWarehouse] Still on login page after button click, trying Enter key"
          password_el_retry = browser.at_css("##{password_id}") rescue nil
          if password_el_retry
            password_el_retry.focus rescue nil
          end
          browser.keyboard.type(:Enter)
        end

        logger.info "[ChefsWarehouse] Form submitted, waiting for response..."
        wait_for_page_load
        sleep 5 # Extra wait for SPA navigation after login

        logger.info "[ChefsWarehouse] Post-login URL: #{browser.current_url}"

        # Check for login success — multiple strategies
        if logged_in?
          save_session
          credential.mark_active!
          logger.info "[ChefsWarehouse] Login successful"
          true
        elsif url_indicates_login_success?
          save_session
          credential.mark_active!
          logger.info "[ChefsWarehouse] Login successful (detected via URL change)"
          true
        else
          full_error = diagnose_login_failure
          credential.mark_failed!(full_error)
          raise AuthenticationError, full_error
        end
      end
    end

    def logged_in?
      # Check for authenticated-only elements
      LOGGED_IN_SELECTORS.each do |selector|
        return true if browser.at_css(selector)
      end

      # If the page has a "Log In" or "Sign Up" link, we are NOT logged in
      has_login_link = browser.at_css("a.log-in, a.sign-in, a[href*='/login']")
      has_signup_link = browser.at_css("a.sign-up, a[href*='/sign-up']")
      if has_login_link || has_signup_link
        logger.debug "[ChefsWarehouse] Login/signup links found — not logged in"
        return false
      end

      # Check page text for logged-in indicators (exclude the login page itself)
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 3000)") rescue ""
      is_login_page = body_text.match?(/forgot password|create an account|sign in|stay signed in/i)
      return false if is_login_page

      # Positive signals from page text
      return true if body_text.match?(/my account|order guide|sign out|log ?out|my orders/i)

      false
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
            logger.warn "[ChefsWarehouse] Failed to scrape SKU #{sku}: #{e.message}"
          end

          rate_limit_delay
        end
      end

      results
    end

    def add_to_cart(items, delivery_date: nil)
      @target_delivery_date = delivery_date

      with_browser do
        unless restore_session && logged_in?
          perform_login_steps
          save_session
        end

        added_items = []
        failed_items = []

        items.each do |item|
          begin
            add_single_item_to_cart(item)
            added_items << item
            logger.info "[ChefsWarehouse] Added SKU #{item[:sku]} (qty: #{item[:quantity]})"
          rescue => e
            logger.warn "[ChefsWarehouse] Failed to add SKU #{item[:sku]}: #{e.message}"
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

    def checkout
      with_browser do
        navigate_to("#{BASE_URL}/cart")
        wait_for_selector(".cart-page, .shopping-cart")

        validate_cart_before_checkout

        minimum_check = check_order_minimum_at_checkout
        unless minimum_check[:met]
          raise OrderMinimumError.new(
            "Order minimum not met",
            minimum: minimum_check[:minimum],
            current_total: minimum_check[:current]
          )
        end

        unavailable = detect_unavailable_items_in_cart
        if unavailable.any?
          raise ItemUnavailableError.new(
            "#{unavailable.count} item(s) are unavailable",
            items: unavailable
          )
        end

        click(".checkout-btn, .proceed-checkout")
        wait_for_selector(".checkout-page, .order-summary")

        click(".place-order, .submit-order")
        wait_for_confirmation_or_error

        {
          confirmation_number: extract_text(".order-number, .confirmation-id"),
          total: extract_price(extract_text(".order-total, .grand-total")),
          delivery_date: extract_text(".delivery-date, .ship-date")
        }
      end
    end

    private

    def add_single_item_to_cart(item)
      # Navigate directly to the product page - CW has predictable URLs
      product_url = "#{BASE_URL}/products/#{item[:sku]}/"
      navigate_to(product_url)
      sleep 3 # Wait for SPA to render

      # Check if we landed on a valid product page
      page_has_product = browser.evaluate(<<~JS)
        (function() {
          // Check for product detail indicators
          var hasProductName = !!document.querySelector('.product-name, .product-title, h1');
          var hasAddButton = !!document.querySelector('.add-to-cart-btn, button.add-to-cart');
          var hasPrice = document.body.innerText.match(/\\$\\d+\\.\\d{2}/);
          return hasProductName || hasAddButton || hasPrice;
        })()
      JS

      unless page_has_product
        # Fallback: try searching for the product
        logger.debug "[ChefsWarehouse] Direct product URL didn't work, trying search"
        encoded_sku = CGI.escape(item[:sku].to_s)
        navigate_to("#{BASE_URL}/search?q=#{encoded_sku}")
        sleep 3

        # Find and click the product link
        clicked = browser.evaluate(<<~JS)
          (function() {
            var links = document.querySelectorAll('a[href*="#{item[:sku]}"]');
            for (var link of links) {
              if (link.href.includes('/products/')) {
                link.click();
                return true;
              }
            }
            return false;
          })()
        JS

        if clicked
          sleep 3
        else
          raise ScrapingError, "Product not found for SKU #{item[:sku]}"
        end
      end

      # Now we should be on the product detail page
      add_product_from_detail_page(item)
    end

    def add_product_from_detail_page(item)
      # CW is a Vue.js SPA - use JavaScript to interact with form elements
      # Set quantity if needed
      if item[:quantity].to_i > 1
        browser.evaluate(<<~JS)
          (function() {
            var qtyInputs = document.querySelectorAll('input[type="number"], input.qty-input, input[name="quantity"], .quantity-input input');
            for (var input of qtyInputs) {
              if (input.offsetParent !== null) { // visible
                input.value = '#{item[:quantity]}';
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
              }
            }
            return false;
          })()
        JS
        sleep 0.5
      end

      # Click add to cart using JavaScript (handles Vue.js event binding)
      clicked = browser.evaluate(<<~JS)
        (function() {
          // Find visible add-to-cart button
          var selectors = [
            '.add-to-cart-btn',
            'button.add-to-cart',
            '.add-to-cart',
            '#add-to-cart',
            'button[class*="add-to-cart"]',
            '.pdp-add-to-cart'
          ];

          for (var sel of selectors) {
            var buttons = document.querySelectorAll(sel);
            for (var btn of buttons) {
              // Check if button is in viewport or make it visible
              btn.scrollIntoView({ behavior: 'instant', block: 'center' });

              // Trigger click
              btn.click();
              return { clicked: true, selector: sel };
            }
          }

          // Fallback: find any button with "add" text
          var allButtons = document.querySelectorAll('button');
          for (var btn of allButtons) {
            if (btn.innerText.toLowerCase().includes('add to cart')) {
              btn.scrollIntoView({ behavior: 'instant', block: 'center' });
              btn.click();
              return { clicked: true, method: 'text-match' };
            }
          }

          return { clicked: false };
        })()
      JS

      unless clicked && clicked["clicked"]
        raise ScrapingError, "Add to cart button not found for SKU #{item[:sku]}"
      end

      logger.debug "[ChefsWarehouse] Clicked add-to-cart: #{clicked.inspect}"
      wait_for_cart_confirmation
    end

    def wait_for_cart_confirmation
      begin
        wait_for_any_selector(
          ".cart-notification",
          ".added-message",
          ".cart-popup",
          ".cart-updated",
          ".success-message",
          timeout: 5
        )
        sleep 1 # Brief pause before next item
      rescue ScrapingError
        # Check if cart count changed instead
        logger.debug "[ChefsWarehouse] No confirmation modal, checking cart state"
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

    protected

    def perform_login_steps
      login_url = credential.supplier.login_url.presence || "#{BASE_URL}/login"
      navigate_to(login_url)
      sleep 3

      email_field = discover_field(EMAIL_SELECTORS, "email/username")
      password_field = discover_field(PASSWORD_SELECTORS, "password")

      if email_field && password_field
        fill_element(email_field, credential.username, "email")
        fill_element(password_field, credential.password, "password")

        submit_btn = discover_field(SUBMIT_SELECTORS, "submit button")
        if submit_btn
          submit_btn.click rescue submit_btn.evaluate("this.click()")
        else
          browser.keyboard.type(:Enter)
        end
      end

      wait_for_page_load
      sleep 3
    end

    private

    # ── Field discovery ─────────────────────────────────────────────
    # Iterates an array of CSS selectors, returns the first visible element found
    def discover_field(selectors, label)
      selectors.each do |sel|
        begin
          elements = browser.css(sel)
          elements.each do |el|
            visible = el.evaluate(<<~JS) rescue false
              var s = window.getComputedStyle(this);
              s.display !== 'none' && s.visibility !== 'hidden' &&
              s.opacity !== '0' && this.offsetWidth > 0 && this.offsetHeight > 0
            JS

            if visible
              logger.info "[ChefsWarehouse] Found #{label} field via '#{sel}'"
              return el
            end
          end
        rescue => e
          logger.debug "[ChefsWarehouse] Selector '#{sel}' raised: #{e.message}"
        end
      end

      # Fallback: try to find ANY input by scanning all inputs on page
      if label.include?("email") || label.include?("username")
        fallback = browser.evaluate(<<~JS) rescue nil
          (function() {
            var inputs = document.querySelectorAll('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])');
            for (var i = 0; i < inputs.length; i++) {
              var inp = inputs[i];
              var t = (inp.type || '').toLowerCase();
              var n = (inp.name || '').toLowerCase();
              var p = (inp.placeholder || '').toLowerCase();
              if (t === 'email' || n.includes('email') || n.includes('user') || p.includes('email') || p.includes('user')) {
                return { found: true, index: i, type: t, name: inp.name, placeholder: inp.placeholder };
              }
            }
            // If no match, return info about the first text/email input
            for (var i = 0; i < inputs.length; i++) {
              var t = (inputs[i].type || '').toLowerCase();
              if (t === 'text' || t === 'email' || t === '') {
                return { found: true, index: i, type: t, name: inputs[i].name, isGuess: true };
              }
            }
            return { found: false, inputCount: inputs.length };
          })()
        JS

        if fallback && fallback["found"]
          all_inputs = browser.css('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])')
          idx = fallback["index"]
          if idx && idx < all_inputs.length
            el = all_inputs[idx]
            guess_note = fallback["isGuess"] ? " (best guess)" : ""
            logger.info "[ChefsWarehouse] Found #{label} field via JS scan: type=#{fallback['type']}, name=#{fallback['name']}#{guess_note}"
            return el
          end
        end
      end

      if label.include?("password")
        pw_el = browser.at_css("input[type='password']") rescue nil
        if pw_el
          logger.info "[ChefsWarehouse] Found password field via type='password' fallback"
          return pw_el
        end
      end

      logger.warn "[ChefsWarehouse] Could not find #{label} field with any selector"
      nil
    end

    # ── Fill a specific element with value ──────────────────────────
    # For Vue.js SPAs, use JavaScript-based filling to avoid stale element references
    def fill_element(element, value, label)
      # First try to get a stable selector for the element
      selector = get_element_selector(element)
      escaped_value = value.gsub("\\", "\\\\\\\\").gsub("'", "\\\\'")

      # Use JavaScript to fill the field - more robust for SPAs
      filled = browser.evaluate(<<~JS) rescue false
        (function() {
          var el = document.querySelector('#{selector}');
          if (!el) return false;

          // Clear and set value using native setter to trigger Vue/React bindings
          var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          el.focus();
          el.dispatchEvent(new Event('focus', { bubbles: true }));
          nativeSetter.call(el, '');
          el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
          nativeSetter.call(el, '#{escaped_value}');

          // Vue 3 v-model listens for InputEvent, not generic Event
          el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '#{escaped_value}', inputType: 'insertText' }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          el.dispatchEvent(new Event('blur', { bubbles: true }));

          return el.value === '#{escaped_value}';
        })()
      JS

      if filled
        logger.info "[ChefsWarehouse] Filled #{label} via JS (selector: #{selector})"
        return
      end

      # Fallback: try direct element interaction
      begin
        element.focus
        element.type(value, :clear)
        logger.info "[ChefsWarehouse] Filled #{label} via focus+type"
      rescue Ferrum::NodeNotFoundError, Ferrum::BrowserError => e
        logger.debug "[ChefsWarehouse] Element interaction failed for #{label}: #{e.message}"
        # Element was removed from DOM - try finding it again
        retry_fill_by_label(label, value)
      end
    end

    # Get a CSS selector that can identify this element
    def get_element_selector(element)
      selector = element.evaluate(<<~JS) rescue nil
        (function() {
          var el = this;
          if (el.id) return '#' + el.id;
          if (el.name) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
          if (el.type) return el.tagName.toLowerCase() + '[type="' + el.type + '"]';
          return el.tagName.toLowerCase();
        })()
      JS
      selector || "input"
    end

    # Retry filling a field by searching for it again
    def retry_fill_by_label(label, value)
      escaped_value = value.gsub("\\", "\\\\\\\\").gsub("'", "\\\\'")

      if label.include?("email") || label.include?("username")
        browser.evaluate(<<~JS)
          (function() {
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            function fillInput(inp, val) {
              inp.focus();
              inp.dispatchEvent(new Event('focus', { bubbles: true }));
              nativeSetter.call(inp, '');
              inp.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
              nativeSetter.call(inp, val);
              inp.dispatchEvent(new InputEvent('input', { bubbles: true, data: val, inputType: 'insertText' }));
              inp.dispatchEvent(new Event('change', { bubbles: true }));
              inp.dispatchEvent(new Event('blur', { bubbles: true }));
            }
            // CW uses type=text for email field, not type=email
            var pwField = document.querySelector('input[type="password"]');
            if (pwField) {
              var container = pwField.closest('form') || pwField.parentElement?.parentElement?.parentElement;
              if (container) {
                var textInputs = container.querySelectorAll('input[type="text"], input[type="email"]');
                for (var inp of textInputs) {
                  if (inp.offsetParent !== null) {
                    fillInput(inp, '#{escaped_value}');
                    return true;
                  }
                }
              }
            }
            // Fallback to any visible text/email input
            var inputs = document.querySelectorAll('input[type="email"], input[type="text"]');
            for (var inp of inputs) {
              if (inp.offsetParent !== null) {
                fillInput(inp, '#{escaped_value}');
                return true;
              }
            }
            return false;
          })()
        JS
        logger.info "[ChefsWarehouse] Filled #{label} via retry JS scan"
      elsif label.include?("password")
        browser.evaluate(<<~JS)
          (function() {
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            var inputs = document.querySelectorAll('input[type="password"]');
            for (var inp of inputs) {
              if (inp.offsetParent !== null) {
                inp.focus();
                inp.dispatchEvent(new Event('focus', { bubbles: true }));
                nativeSetter.call(inp, '');
                inp.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
                nativeSetter.call(inp, '#{escaped_value}');
                inp.dispatchEvent(new InputEvent('input', { bubbles: true, data: '#{escaped_value}', inputType: 'insertText' }));
                inp.dispatchEvent(new Event('change', { bubbles: true }));
                inp.dispatchEvent(new Event('blur', { bubbles: true }));
                return true;
              }
            }
            return false;
          })()
        JS
        logger.info "[ChefsWarehouse] Filled #{label} via retry JS scan"
      end
    end

    # ── URL-based login detection ───────────────────────────────────
    def url_indicates_login_success?
      current = browser.current_url.to_s.downcase rescue ""
      # Only count as success if we're on a known authenticated-only page
      success_patterns = %w[/dashboard /account /my-account /orders /order-guide]
      success_patterns.any? { |p| current.include?(p) }
    end

    # ── Full page diagnostic dump ───────────────────────────────────
    def capture_page_diagnostics
      url = browser.current_url rescue "unknown"
      title = browser.evaluate("document.title") rescue "unknown"

      # Get all input fields on the page for debugging
      inputs_info = browser.evaluate(<<~JS) rescue "could not enumerate inputs"
        (function() {
          var inputs = document.querySelectorAll('input, select, textarea, button');
          var info = [];
          for (var i = 0; i < inputs.length && i < 20; i++) {
            var el = inputs[i];
            var s = window.getComputedStyle(el);
            var visible = s.display !== 'none' && s.visibility !== 'hidden' && el.offsetWidth > 0;
            info.push({
              tag: el.tagName,
              type: el.type || '',
              name: el.name || '',
              id: el.id || '',
              placeholder: el.placeholder || '',
              className: (el.className || '').toString().substring(0, 60),
              visible: visible
            });
          }
          return JSON.stringify(info);
        })()
      JS

      # Get page body text snippet
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 500)") rescue ""

      # Get all iframes (login might be in an iframe)
      iframes_info = browser.evaluate(<<~JS) rescue "none"
        (function() {
          var frames = document.querySelectorAll('iframe');
          var info = [];
          for (var i = 0; i < frames.length; i++) {
            info.push({ src: frames[i].src || '', id: frames[i].id || '', name: frames[i].name || '' });
          }
          return JSON.stringify(info);
        })()
      JS

      parts = [
        "URL: #{url}",
        "Title: '#{title}'",
        "Page inputs: #{inputs_info}",
        "Iframes: #{iframes_info}",
        "Page text: #{body_text.to_s.strip.truncate(300)}"
      ]

      parts.join(" | ")
    end

    # ── Product scraping ────────────────────────────────────────────
    def scrape_product(sku)
      navigate_to("#{BASE_URL}/product/#{sku}")

      return nil unless browser.at_css(".product-detail, .pdp-container")

      {
        supplier_sku: sku,
        supplier_name: extract_text(".product-name, h1.title"),
        current_price: extract_price(extract_text(".price, .product-price")),
        pack_size: extract_text(".pack-info, .unit-size"),
        in_stock: browser.at_css(".out-of-stock, .sold-out").nil?,
        scraped_at: Time.current
      }
    end

    # ── Catalog search ──────────────────────────────────────────────
    def search_supplier_catalog(term, max: 20)
      encoded = CGI.escape(term)
      navigate_to("#{BASE_URL}/search?q=#{encoded}")
      sleep 2 # SPA rendering time

      # CW stores product data as JSON in hidden inputs with data-object attribute
      products = extract_products_from_data_objects(max)

      # Fallback: parse visible .product-item elements
      if products.empty?
        products = extract_products_from_items(max)
      end

      products
    end

    # Primary extraction: CW embeds JSON in hidden input[data-sku][data-object]
    def extract_products_from_data_objects(max)
      raw = browser.evaluate(<<~JS) rescue []
        (function() {
          var results = [];
          var inputs = document.querySelectorAll("input[data-sku][data-object]");
          for (var i = 0; i < inputs.length && results.length < #{max}; i++) {
            try {
              var obj = JSON.parse(inputs[i].getAttribute("data-object"));
              if (obj && obj.sku && obj.name) {
                results.push({
                  sku: obj.sku,
                  name: (obj.brand ? obj.name + " - " + obj.brand : obj.name).substring(0, 255),
                  price: obj.price || null,
                  pack_size: obj.pack_size || "",
                  unit_of_measure: obj.unit_of_measure || "",
                  url: obj.url || "",
                  in_stock: true
                });
              }
            } catch(e) {}
          }
          return results;
        })()
      JS

      (raw || []).map do |item|
        pack = item["pack_size"].to_s.strip.presence
        product_url = item["url"].to_s.presence
        product_url = "#{BASE_URL}#{product_url}" if product_url && !product_url.start_with?("http")
        {
          supplier_sku: item["sku"],
          supplier_name: item["name"],
          current_price: item["price"].is_a?(Numeric) ? item["price"] : nil,
          pack_size: pack,
          supplier_url: product_url,
          in_stock: item["in_stock"] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    end

    # Fallback: parse visible .product-item divs
    def extract_products_from_items(max)
      raw = browser.evaluate(<<~JS) rescue []
        (function() {
          var results = [];
          var items = document.querySelectorAll(".product-item");
          for (var i = 0; i < items.length && results.length < #{max}; i++) {
            var text = items[i].innerText.trim();
            var lines = text.split("\\n").map(function(l) { return l.trim(); }).filter(Boolean);
            if (lines.length < 3) continue;

            var name = lines[0] || "";
            var brand = lines.length > 2 ? lines[1] : "";
            var sku = "";
            var price = null;
            var pack = "";

            for (var j = 0; j < lines.length; j++) {
              var line = lines[j];
              if (line.match(/^[A-Z0-9]{2,}$/i) && !line.match(/add to cart/i)) sku = line;
              if (line.match(/^\\$/)) {
                var m = line.match(/[\\d,.]+/);
                if (m) price = parseFloat(m[0].replace(/,/g, ""));
              }
              if (line.match(/\\d+x\\d+|LB|OZ|CS|EA|CT|GAL/i) && !line.match(/^\\$/)) pack = line;
            }

            if (name && name.length > 2) {
              var fullName = brand ? name + " - " + brand : name;
              results.push({sku: sku || name.toLowerCase().replace(/[^a-z0-9]+/g, "-"), name: fullName.substring(0, 255), price: price, pack: pack, in_stock: true});
            }
          }
          return results;
        })()
      JS

      (raw || []).map do |item|
        sku = item["sku"]
        {
          supplier_sku: sku,
          supplier_name: item["name"],
          current_price: item["price"].is_a?(Numeric) ? item["price"] : nil,
          pack_size: item["pack"].presence,
          supplier_url: sku.present? ? "#{BASE_URL}/products/#{sku}/" : nil,
          in_stock: item["in_stock"] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    end

    # ── Checkout helpers ────────────────────────────────────────────
    def check_order_minimum_at_checkout
      subtotal_text = extract_text(".subtotal, .cart-subtotal")
      current_total = extract_price(subtotal_text) || 0

      {
        met: current_total >= ORDER_MINIMUM,
        minimum: ORDER_MINIMUM,
        current: current_total
      }
    end

    def detect_unavailable_items_in_cart
      unavailable = []

      browser.css(".cart-item, .line-item").each do |item|
        if item.at_css(".out-of-stock, .unavailable")
          unavailable << {
            sku: item.at_css("[data-sku], [data-product-id]")&.attribute("data-sku"),
            name: item.at_css(".product-name, .item-title")&.text&.strip,
            message: item.at_css(".stock-message")&.text&.strip
          }
        end
      end

      unavailable
    end

    def validate_cart_before_checkout
      detect_error_conditions

      if browser.at_css(".empty-cart, .no-items")
        raise ScrapingError, "Cart is empty"
      end
    end

    def wait_for_confirmation_or_error
      start_time = Time.current
      timeout = 30

      loop do
        return true if browser.at_css(".confirmation, .order-success, .thank-you")

        error_msg = browser.at_css(".error, .checkout-error")&.text&.strip
        if error_msg
          raise ScrapingError, "Checkout failed: #{error_msg}"
        end

        raise ScrapingError, "Checkout timeout" if Time.current - start_time > timeout
        sleep 0.5
      end
    end
  end
end
