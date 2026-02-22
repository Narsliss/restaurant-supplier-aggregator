module Scrapers
  class ChefsWarehouseScraper < BaseScraper
    BASE_URL = 'https://www.chefswarehouse.com'.freeze
    ORDER_URL = 'https://order.chefswarehouse.com'.freeze
    ORDER_MINIMUM = 200.00
    CHECKOUT_LIVE = false # HARD SAFETY GATE: set to true ONLY when ready for live CW orders

    # Override with_browser to use longer timeout and stealth options
    # CW's Vue.js SPA needs more time and may trigger bot detection
    def with_browser
      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'

      browser_opts = {
        headless: headless_mode,
        timeout: 60,
        process_timeout: 30,
        window_size: [1920, 1080]
      }

      browser_opts[:browser_options] = {
        "no-sandbox": true,
        "disable-gpu": true,
        "disable-dev-shm-usage": true,
        "disable-blink-features": 'AutomationControlled'
      }

      # Allow custom Chrome/Chromium path via environment variable
      browser_opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?

      logger.info "[ChefsWarehouse] Starting browser (headless=#{headless_mode}, timeout=60)"
      @browser = Ferrum::Browser.new(**browser_opts)
      yield(browser)
    ensure
      browser&.quit
    end

    # Chef's Warehouse categories for catalog browsing
    # Categories are browsed via URL pattern: /shop/category-slug
    CW_CATEGORIES = %w[
      beef
      poultry
      pork
      seafood
      lamb-veal-game
      cheese
      dairy
      produce
      dry-goods
      beverages
      specialty-foods
      frozen
      equipment
      paper-goods
      cleaning-supplies
    ].freeze

    # Broad selectors — the site is a JS SPA with dynamically generated IDs
    # The login form uses type=text for email (not type=email) and has uid-* IDs
    EMAIL_SELECTORS = [
      '#email', '#username', '#loginEmail', '#userEmail',
      "input[name='email']", "input[name='username']", "input[name='loginId']",
      "input[type='email']",
      # CW uses dynamic uid-* IDs, so we need to find input by context
      "input[id^='uid-'][type='text']",
      "input[placeholder*='email' i]",
      "input[placeholder*='username' i]", "input[aria-label*='email' i]"
    ].freeze

    PASSWORD_SELECTORS = [
      '#password', '#loginPassword', '#userPassword',
      "input[name='password']", "input[type='password']",
      "input[id^='uid-'][type='password']",
      "input[placeholder*='password' i]", "input[aria-label*='password' i]"
    ].freeze

    SUBMIT_SELECTORS = [
      '.btn-sign-in',
      'button.btn-sign-in',
      "button[type='submit'].btn-secondary",
      '.login-btn', '.sign-in-button', '.btn-login', '.login-button',
      "button[data-testid*='login' i]", "button[data-testid*='sign' i]",
      # CW has multiple submit buttons - look for Sign In text
      "button[type='submit']"
    ].freeze

    LOGGED_IN_SELECTORS = [
      '.account-menu', '.user-nav', '.my-account-link', '.account-dropdown',
      '.user-menu', '.logged-in', '.user-greeting',
      "[data-testid='account']", "[data-testid='user-menu']",
      "a[href*='my-account']", "a[href*='dashboard']",
      "a[href*='logout']", "a[href*='sign-out']", "button[aria-label*='account' i]",
      '.header-account', '#account-menu', '#user-nav'
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
            logger.info '[ChefsWarehouse] Restored session successfully'
            return true
          end
          logger.info '[ChefsWarehouse] Session restore failed, proceeding with fresh login'
        end

        # Navigate to login page
        navigate_to(login_url)
        sleep 3 # Extra wait for SPA rendering
        logger.info "[ChefsWarehouse] On login page: #{browser.current_url}"

        # Check if we got redirected
        logger.info "[ChefsWarehouse] Redirected to: #{browser.current_url}" if browser.current_url != login_url

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

        unless login_result && login_result['found']
          dump = capture_page_diagnostics
          error_detail = login_result&.dig('error') || 'unknown'
          raise AuthenticationError, "Login form not found (#{error_detail}). #{dump}"
        end

        logger.info "[ChefsWarehouse] Found login form: email=##{login_result['emailId']}, password=##{login_result['passwordId']}, submit=##{login_result['submitId']}"

        # Fill credentials using Ferrum's native CDP keyboard input
        # Vue 3 v-model only responds to real keyboard events from Chrome DevTools Protocol,
        # not synthetic JS events or nativeSetter tricks
        email_id = login_result['emailId']
        password_id = login_result['passwordId']
        submit_id = login_result['submitId']

        # Get Ferrum element references via their discovered IDs
        email_el = browser.at_css("##{email_id}")
        password_el = browser.at_css("##{password_id}")

        raise AuthenticationError, 'Could not get element references for login fields' unless email_el && password_el

        # Fill email field using real keyboard input
        logger.info '[ChefsWarehouse] Typing username into email field'
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
        logger.info '[ChefsWarehouse] Typing password into password field'
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

        logger.info '[ChefsWarehouse] Credentials entered, clicking submit'

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
        still_on_login = begin
          browser.current_url.to_s.include?('/login')
        rescue StandardError
          false
        end
        if still_on_login
          logger.info '[ChefsWarehouse] Still on login page after button click, trying Enter key'
          password_el_retry = begin
            browser.at_css("##{password_id}")
          rescue StandardError
            nil
          end
          if password_el_retry
            begin
              password_el_retry.focus
            rescue StandardError
              nil
            end
          end
          browser.keyboard.type(:Enter)
        end

        logger.info '[ChefsWarehouse] Form submitted, waiting for response...'
        wait_for_page_load
        sleep 5 # Extra wait for SPA navigation after login

        logger.info "[ChefsWarehouse] Post-login URL: #{browser.current_url}"

        # Check for login success — multiple strategies
        if logged_in?
          save_session
          credential.mark_active!
          logger.info '[ChefsWarehouse] Login successful'
          true
        elsif url_indicates_login_success?
          save_session
          credential.mark_active!
          logger.info '[ChefsWarehouse] Login successful (detected via URL change)'
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
        logger.debug '[ChefsWarehouse] Login/signup links found — not logged in'
        return false
      end

      # Check page text for logged-in indicators (exclude the login page itself)
      body_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 3000)')
      rescue StandardError
        ''
      end
      is_login_page = body_text.match?(/forgot password|create an account|sign in|stay signed in/i)
      return false if is_login_page

      # Positive signals from page text
      return true if body_text.match?(/my account|order guide|sign out|log ?out|my orders/i)

      false
    end

    def scrape_prices(product_skus)
      results = []

      with_browser do
        # Restore session inline — do NOT call login() which has its own
        # with_browser block and would create a nested browser (killing ours).
        if restore_session
          navigate_to(BASE_URL)
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
            logger.warn "[ChefsWarehouse] Failed to scrape SKU #{sku}: #{e.message}"
          end

          rate_limit_delay
        end

        # While browser is still open and authenticated, grab the delivery address
        begin
          extract_delivery_address
        rescue StandardError => e
          logger.warn "[ChefsWarehouse] Address extraction failed (non-fatal): #{e.message}"
        end
      end

      results
    end

    def clear_cart
      with_browser do
        unless restore_session && logged_in?
          perform_login_steps
          save_session
        end

        navigate_to("#{BASE_URL}/cart")
        sleep 3

        # Check if cart has items
        cart_count = browser.evaluate(<<~JS)
          (function() {
            // Look for cart count in the shopping cart button (e.g. "10")
            var cartBtn = document.querySelector('.shopping-cart-btn, .mobile-shopping-cart-btn');
            if (cartBtn) {
              var num = parseInt(cartBtn.innerText.trim());
              if (!isNaN(num)) return num;
            }
            // Fallback: count quantity inputs on the cart page
            var inputs = document.querySelectorAll('input[type="number"]');
            return inputs.length;
          })()
        JS

        if cart_count.to_i == 0
          logger.info '[ChefsWarehouse] Cart is already empty'
          return
        end

        logger.info "[ChefsWarehouse] Clearing cart (#{cart_count} items)..."

        # Click the "Empty Cart" button
        clicked_empty = browser.evaluate(<<~JS)
          (function() {
            var buttons = document.querySelectorAll('button, a');
            for (var btn of buttons) {
              var text = (btn.innerText || '').trim().toLowerCase();
              if (text === 'empty cart' && btn.offsetParent !== null) {
                btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                btn.click();
                return true;
              }
            }
            return false;
          })()
        JS

        unless clicked_empty
          logger.warn '[ChefsWarehouse] Could not find Empty Cart button'
          return
        end

        sleep 1

        # CW shows a confirmation modal: "You're about to remove all items from your cart"
        # Confirm by clicking the second "Empty Cart" button in the modal
        confirmed = browser.evaluate(<<~JS)
          (function() {
            // Look for modal confirmation button — it's the "Empty Cart" button inside the modal
            var modal = document.querySelector('.modal, [class*="modal"], [role="dialog"]');
            if (modal) {
              var buttons = modal.querySelectorAll('button, a');
              for (var btn of buttons) {
                var text = (btn.innerText || '').trim().toLowerCase();
                if (text === 'empty cart') {
                  btn.click();
                  return { confirmed: true, method: 'modal-button' };
                }
              }
            }

            // Fallback: find all "Empty Cart" buttons and click the last one (modal confirm)
            var allBtns = document.querySelectorAll('button, a');
            var emptyBtns = [];
            for (var btn of allBtns) {
              var text = (btn.innerText || '').trim().toLowerCase();
              if (text === 'empty cart' && btn.offsetParent !== null) {
                emptyBtns.push(btn);
              }
            }
            if (emptyBtns.length > 1) {
              emptyBtns[emptyBtns.length - 1].click();
              return { confirmed: true, method: 'last-empty-btn' };
            }

            return { confirmed: false };
          })()
        JS

        if confirmed && confirmed['confirmed']
          logger.info "[ChefsWarehouse] Cart emptied (#{confirmed['method']})"
          sleep 2 # Wait for cart to clear
        else
          logger.warn '[ChefsWarehouse] Could not confirm Empty Cart modal'
        end
      end
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
          rescue StandardError => e
            logger.warn "[ChefsWarehouse] Failed to add SKU #{item[:sku]}: #{e.message}"
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
            logger.warn "[ChefsWarehouse] #{failed_items.count} item(s) skipped (unavailable): " \
                        "#{failed_items.map { |i| i[:sku] }.join(', ')}"
          end
        end

        { added: added_items.count, failed: failed_items }
      end
    end

    def checkout(dry_run: false)
      effective_dry_run = dry_run || !CHECKOUT_LIVE
      logger.info "[ChefsWarehouse] checkout starting (dry_run=#{effective_dry_run}, CHECKOUT_LIVE=#{CHECKOUT_LIVE})"

      with_browser do
        # Step 1: Restore session / login
        unless restore_session && logged_in?
          perform_login_steps
          save_session
        end

        # Step 2: Navigate to cart page
        navigate_to_cart_page

        # Step 3: Extract cart data (JS-based DOM scanning)
        cart_data = extract_cart_data
        logger.info "[ChefsWarehouse] Cart: #{cart_data[:item_count]} items, subtotal=#{cart_data[:subtotal]}"

        # Step 4: Validate cart
        raise ScrapingError, 'Cart is empty' if cart_data[:item_count] == 0

        # Step 5: Check order minimum
        if cart_data[:subtotal] < ORDER_MINIMUM
          raise OrderMinimumError.new(
            'Order minimum not met',
            minimum: ORDER_MINIMUM,
            current_total: cart_data[:subtotal]
          )
        end

        # Step 6: Check for unavailable items
        if cart_data[:unavailable_items].any?
          raise ItemUnavailableError.new(
            "#{cart_data[:unavailable_items].count} item(s) are unavailable",
            items: cart_data[:unavailable_items]
          )
        end

        # Step 7: Navigate to checkout page
        proceed_to_checkout_page

        # Step 8: Extract checkout/review page data
        checkout_data = extract_checkout_data
        logger.info "[ChefsWarehouse] Checkout: total=#{checkout_data[:total]}, delivery=#{checkout_data[:delivery_date]}"

        # ═══════════════════════════════════════════
        # ═══ SAFETY GATE — DRY RUN CHECK ══════════
        # ═══════════════════════════════════════════
        if effective_dry_run
          logger.info "[ChefsWarehouse] DRY RUN COMPLETE — stopping before final submit"
          logger.info "[ChefsWarehouse] Would have placed order: total=#{checkout_data[:total]}"

          return {
            confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
            total: checkout_data[:total] || cart_data[:subtotal],
            delivery_date: checkout_data[:delivery_date],
            dry_run: true,
            cart_items: cart_data[:items],
            checkout_summary: checkout_data
          }
        end

        # Step 9: LIVE ORDER — Click final submit
        logger.warn "[ChefsWarehouse] PLACING LIVE ORDER — clicking submit"
        click_place_order_button

        # Step 10: Wait for confirmation
        confirmation = wait_for_order_confirmation

        logger.info "[ChefsWarehouse] Order placed: #{confirmation[:confirmation_number]}"
        confirmation
      end
    end

    # Extract delivery address from CW account page.
    # Must be called inside an existing with_browser block (browser already open).
    def extract_delivery_address
      logger.info "[ChefsWarehouse] Extracting delivery address from account..."

      # Try the account dashboard addresses page
      address_urls = [
        "#{BASE_URL}/account-dashboard/addresses/",
        "#{BASE_URL}/account-dashboard/delivery-addresses/",
        "#{BASE_URL}/account-dashboard/"
      ]

      address_urls.each do |url|
        begin
          navigate_to(url)
          sleep 2

          # Log the page content for discovery
          page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
          logger.info "[ChefsWarehouse] Address page (#{url}): #{page_text.first(1500)}"

          # Try to extract address via JavaScript - scan for address-like elements
          address = browser.evaluate(<<~JS)
            (function() {
              // Look for common address container patterns
              var selectors = [
                '[class*="address"]',
                '[class*="shipping"]',
                '[class*="delivery"]',
                '[data-address]',
                '[class*="location"]'
              ];

              for (var i = 0; i < selectors.length; i++) {
                var els = document.querySelectorAll(selectors[i]);
                for (var j = 0; j < els.length; j++) {
                  var text = els[j].innerText.trim();
                  // Look for text that contains a ZIP code pattern (basic address heuristic)
                  if (text && text.match(/\\b\\d{5}(-\\d{4})?\\b/) && text.length < 300) {
                    return text;
                  }
                }
              }

              // Fallback: scan all paragraphs and divs for address patterns
              var all = document.querySelectorAll('p, div, span, address');
              for (var k = 0; k < all.length; k++) {
                var t = all[k].innerText.trim();
                // Match: has a ZIP code, has a state abbreviation, reasonable length
                if (t && t.match(/\\b\\d{5}(-\\d{4})?\\b/) && t.match(/\\b[A-Z]{2}\\b/) && t.length > 10 && t.length < 300) {
                  // Avoid nav bars, footers, etc.
                  var parent = all[k].closest('nav, footer, header');
                  if (!parent) return t;
                }
              }

              return null;
            })()
          JS

          if address.present?
            # Clean up: collapse whitespace and newlines
            cleaned = address.gsub(/\s+/, ' ').strip
            logger.info "[ChefsWarehouse] Found delivery address: #{cleaned}"
            @last_delivery_address = cleaned
            return @last_delivery_address
          end
        rescue StandardError => e
          logger.warn "[ChefsWarehouse] Failed to extract address from #{url}: #{e.message}"
        end
      end

      logger.info "[ChefsWarehouse] Could not extract delivery address from any account page"
      @last_delivery_address = nil
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

        raise ScrapingError, "Product not found for SKU #{item[:sku]}" unless clicked

        sleep 3

      end

      # Now we should be on the product detail page
      add_product_from_detail_page(item)
    end

    def add_product_from_detail_page(item)
      qty = item[:quantity].to_i
      qty = 1 if qty < 1

      # CW's Vue.js SPA ignores programmatic quantity input changes.
      # Most reliable approach: click Add to Cart once per unit needed.
      qty.times do |i|
        clicked = browser.evaluate(<<~JS)
          (function() {
            // Phase 1: Scoped to product detail area (not recommendations)
            var pdpContainers = document.querySelectorAll(
              '.product-detail, .pdp-container, .product-info, [class*="product-detail"], [class*="pdp"], main > section:first-child, .product-page'
            );

            for (var container of pdpContainers) {
              var btn = container.querySelector('.add-to-cart-btn, button.add-to-cart, [class*="add-to-cart"]');
              if (btn && btn.offsetParent !== null) {
                btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                btn.click();
                return { clicked: true, selector: 'pdp-scoped', classes: btn.className };
              }
            }

            // Phase 2: First visible add-to-cart button
            var selectors = ['.add-to-cart-btn', 'button.add-to-cart', 'button[class*="add-to-cart"]'];
            for (var sel of selectors) {
              var buttons = document.querySelectorAll(sel);
              for (var btn of buttons) {
                if (btn.offsetParent !== null) {
                  btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                  btn.click();
                  return { clicked: true, selector: sel, classes: btn.className };
                }
              }
            }

            // Phase 3: Any button with "add to cart" text
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

        raise ScrapingError, "Add to cart button not found for SKU #{item[:sku]}" unless clicked && clicked['clicked']

        logger.debug "[ChefsWarehouse] Clicked add-to-cart (#{i + 1}/#{qty}): #{clicked.inspect}"
        wait_for_cart_confirmation

        # Brief pause between clicks to let Vue update the cart state
        sleep 1.5 if i < qty - 1
      end
    end

    def wait_for_cart_confirmation
      wait_for_any_selector(
        '.cart-notification',
        '.added-message',
        '.cart-popup',
        '.cart-updated',
        '.success-message',
        timeout: 5
      )
      sleep 1 # Brief pause before next item
    rescue ScrapingError
      # Check if cart count changed instead
      logger.debug '[ChefsWarehouse] No confirmation modal, checking cart state'
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

    # Scrape order guides from Chef's Warehouse.
    # CW has an order guides page at /account-dashboard/order-guides/
    # which may contain one or more named order guides.
    def scrape_supplier_lists
      guides_url = "#{BASE_URL}/account-dashboard/order-guides/"
      logger.info "[ChefsWarehouse] Navigating to order guides: #{guides_url}"

      begin
        navigate_to(guides_url)
      rescue Ferrum::PendingConnectionsError
        logger.warn '[ChefsWarehouse] PendingConnectionsError on order guides page — continuing'
      end
      sleep 5

      # CW order guides page (Vue.js SPA) shows guide cards inside
      # section.order-guide-items containers. Each guide is an <a> tag
      # with class "cw-router-link" inside a div.guide-wrapper.
      #
      # Link hrefs:
      #   /account-dashboard/order-guides/detail/?id=-1         (Recently Purchased)
      #   /account-dashboard/order-guides/detail/?id=389493&type=user (user guide)
      #   /account-dashboard/order-guides/detail/?id=334597&type=csr  (CW-managed)
      #
      # Guide names in h5.item-title, item counts in li.item-count.
      guides_data = browser.evaluate(<<~JS)
        (function() {
          var guides = [];
          var seen = {};

          // Find guide links inside guide-wrapper containers
          var wrappers = document.querySelectorAll('.guide-wrapper');
          for (var i = 0; i < wrappers.length; i++) {
            var link = wrappers[i].querySelector('a[href*="order-guides/detail"]');
            if (!link) continue;

            var href = link.getAttribute('href') || '';
            var titleEl = wrappers[i].querySelector('.item-title, h5');
            var countEl = wrappers[i].querySelector('.item-count');

            var name = titleEl ? titleEl.innerText.trim() : '';
            var countMatch = countEl ? countEl.innerText.match(/(\\d+)/) : null;
            var itemCount = countMatch ? parseInt(countMatch[1]) : 0;

            // Extract guide ID from query parameter ?id=XXXXX
            var idMatch = href.match(/[?&]id=([^&]+)/);
            var guideId = idMatch ? idMatch[1] : null;

            if (name && guideId && !seen[guideId]) {
              seen[guideId] = true;
              guides.push({
                name: name.substring(0, 255),
                remote_id: guideId,
                url: href,
                item_count: itemCount
              });
            }
          }

          // Fallback: scan all links to order-guides/detail
          if (guides.length === 0) {
            var links = document.querySelectorAll('a[href*="order-guides/detail"]');
            for (var j = 0; j < links.length; j++) {
              var lhref = links[j].getAttribute('href') || '';
              var ltext = (links[j].innerText || '').trim().split('\\n')[0] || '';
              var lidMatch = lhref.match(/[?&]id=([^&]+)/);
              var lid = lidMatch ? lidMatch[1] : null;

              if (ltext && lid && !seen[lid]) {
                seen[lid] = true;
                guides.push({ name: ltext.substring(0, 255), remote_id: lid, url: lhref, item_count: 0 });
              }
            }
          }

          return JSON.stringify(guides);
        })()
      JS

      parsed_guides = begin
        JSON.parse(guides_data)
      rescue StandardError
        []
      end

      logger.info "[ChefsWarehouse] Found #{parsed_guides.size} order guides"

      # If no guides found, treat the current page as a single guide
      if parsed_guides.empty?
        products = extract_order_guide_products
        return [{
          name: 'Order Guide',
          remote_id: 'order-guide',
          url: guides_url,
          list_type: 'order_guide',
          items: products
        }]
      end

      # Scrape products from each guide
      result_lists = []
      parsed_guides.each do |guide|
        guide_name = guide['name']
        guide_url = guide['url']

        logger.info "[ChefsWarehouse] Scraping guide '#{guide_name}' (#{guide['item_count']} items expected)"

        if guide_url.present?
          full_url = guide_url.start_with?('http') ? guide_url : "#{BASE_URL}#{guide_url}"
          begin
            navigate_to(full_url)
          rescue Ferrum::PendingConnectionsError
            logger.warn "[ChefsWarehouse] PendingConnectionsError on guide '#{guide_name}' — continuing"
          end
          sleep 5
        end

        products = extract_order_guide_products
        logger.info "[ChefsWarehouse] Guide '#{guide_name}': #{products.size} products"

        # Determine list type based on guide ID
        list_type = guide['remote_id'] == '-1' ? 'favorites' : 'order_guide'

        result_lists << {
          name: guide_name,
          remote_id: guide['remote_id'],
          url: guide_url,
          list_type: list_type,
          items: products
        }

        rate_limit_delay
      end

      result_lists
    end

    # Extract products from the current order guide detail page.
    #
    # CW guide detail pages (Vue.js SPA) show products as li.cw-list-item
    # elements inside div.order-guide-detail-items. Each item has:
    #   - Name in a.item-title
    #   - SKU in ul.info-list > li.item (second li, after brand)
    #   - Brand in ul.info-list > li.item.body-one > a
    #   - Pack size in span.pack-size
    #   - Price in span.price
    def extract_order_guide_products
      # Scroll to load all products (CW lazy-loads on scroll)
      last_count = 0
      10.times do
        browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
        sleep 2
        current_count = browser.evaluate("document.querySelectorAll('li.cw-list-item').length") rescue 0
        break if current_count == last_count && current_count > 0
        last_count = current_count
      end

      # Extract from guide detail list items
      raw = begin
        browser.evaluate(<<~JS)
          (function() {
            var results = [];
            var seen = {};
            var items = document.querySelectorAll('li.cw-list-item');

            for (var i = 0; i < items.length; i++) {
              var item = items[i];

              // Name from the item-title link
              var nameEl = item.querySelector('a.item-title, .item-title');
              var name = nameEl ? nameEl.innerText.trim() : '';

              // SKU: second <li> in the info-list (first is brand)
              var infoItems = item.querySelectorAll('ul.info-list li.item');
              var sku = '';
              var brand = '';
              for (var j = 0; j < infoItems.length; j++) {
                var liText = infoItems[j].innerText.trim();
                if (infoItems[j].classList.contains('body-one')) {
                  brand = liText;
                } else if (liText.match(/^[A-Z0-9]{2,}$/i)) {
                  sku = liText;
                }
              }

              // Also try extracting SKU from product link href (/products/SKU/)
              if (!sku) {
                var prodLink = item.querySelector('a[href*="/products/"]');
                if (prodLink) {
                  var hrefMatch = prodLink.getAttribute('href').match(/\\/products\\/([^/]+)/);
                  if (hrefMatch) sku = hrefMatch[1];
                }
              }

              if (!sku || !name || seen[sku]) continue;
              seen[sku] = true;

              // Pack size
              var packEl = item.querySelector('.pack-size');
              var packSize = packEl ? packEl.innerText.trim() : '';

              // Price (e.g. "$60.50 / Piece" or "$129.15 / Case")
              var priceEl = item.querySelector('.price');
              var price = null;
              if (priceEl) {
                var priceMatch = priceEl.innerText.match(/\\$(\\d+[,\\d]*\\.\\d{2})/);
                if (priceMatch) price = parseFloat(priceMatch[1].replace(',', ''));
              }

              // Full name with brand
              var fullName = brand ? (name + ' - ' + brand) : name;

              // In stock (check for out-of-stock indicators)
              var outOfStock = item.querySelector('.out-of-stock, [class*="out-of-stock"]');
              var inStock = !outOfStock && !item.innerText.match(/out of stock/i);

              results.push({
                sku: sku,
                name: fullName.substring(0, 255),
                price: price,
                pack_size: packSize,
                in_stock: inStock
              });
            }

            return results;
          })()
        JS
      rescue StandardError
        []
      end

      (raw || []).each_with_index.map do |item, idx|
        {
          sku: item['sku'],
          name: item['name'],
          price: item['price'].is_a?(Numeric) ? item['price'] : nil,
          pack_size: item['pack_size'].to_s.strip.presence,
          quantity: 1,
          in_stock: item['in_stock'] != false,
          position: idx + 1
        }
      end
    end

    protected

    # Robust login flow using JS-based form discovery.
    # Reuses the same approach as the main login() method but without the
    # with_browser wrapper so it can be called from scrape_prices/add_to_cart
    # which already have an open browser session.
    def perform_login_steps
      login_url = credential.supplier.login_url.presence || "#{BASE_URL}/login"
      navigate_to(login_url)
      sleep 3

      logger.info "[ChefsWarehouse] perform_login_steps: on #{browser.current_url}"

      # Use JavaScript to discover the login form — same approach as login()
      login_result = browser.evaluate(<<~JS)
        (function() {
          var result = { found: false, email: null, password: null, button: null };

          var passwordInputs = document.querySelectorAll('input[type="password"]');
          var passwordField = null;
          for (var pw of passwordInputs) {
            if (pw.offsetParent !== null) { passwordField = pw; break; }
          }
          if (!passwordField) return { found: false, error: 'No visible password field' };

          var passwordContainer = passwordField.closest('form') || passwordField.closest('div[class*="login"]') || passwordField.parentElement?.parentElement?.parentElement;
          var emailField = null;

          if (passwordContainer) {
            var containerInputs = passwordContainer.querySelectorAll('input[type="text"], input[type="email"]');
            for (var inp of containerInputs) {
              if (inp.offsetParent !== null && inp !== passwordField) { emailField = inp; break; }
            }
          }
          if (!emailField) {
            var allInputs = document.querySelectorAll('input[type="text"], input[type="email"]');
            for (var inp of allInputs) {
              if (inp.offsetParent !== null) { emailField = inp; break; }
            }
          }
          if (!emailField) return { found: false, error: 'No visible email/text field' };

          var submitButton = null;
          var buttons = document.querySelectorAll('button[type="submit"], button');
          for (var btn of buttons) {
            var text = (btn.innerText || '').trim().toLowerCase();
            if (text === 'sign in' && btn.offsetParent !== null) { submitButton = btn; break; }
          }

          if (!emailField.id) emailField.id = 'cw-temp-email-' + Date.now();
          if (!passwordField.id) passwordField.id = 'cw-temp-password-' + Date.now();
          if (submitButton && !submitButton.id) submitButton.id = 'cw-temp-submit-' + Date.now();

          return {
            found: true,
            emailId: emailField.id,
            passwordId: passwordField.id,
            submitId: submitButton ? submitButton.id : null
          };
        })()
      JS

      unless login_result && login_result['found']
        error_detail = login_result&.dig('error') || 'unknown'
        logger.error "[ChefsWarehouse] perform_login_steps: form not found (#{error_detail})"
        # Fall back to basic selector approach
        email_field = discover_field(EMAIL_SELECTORS, 'email/username')
        password_field = discover_field(PASSWORD_SELECTORS, 'password')
        if email_field && password_field
          fill_element(email_field, credential.username, 'email')
          fill_element(password_field, credential.password, 'password')
          submit_btn = discover_field(SUBMIT_SELECTORS, 'submit button')
          if submit_btn
            begin; submit_btn.click; rescue StandardError; submit_btn.evaluate('this.click()'); end
          else
            browser.keyboard.type(:Enter)
          end
          wait_for_page_load
          sleep 3
        end
        return
      end

      logger.info "[ChefsWarehouse] perform_login_steps: found form — email=##{login_result['emailId']}, submit=##{login_result['submitId']}"

      # Fill using real CDP keyboard input (required for Vue.js v-model)
      email_el = browser.at_css("##{login_result['emailId']}")
      password_el = browser.at_css("##{login_result['passwordId']}")

      unless email_el && password_el
        logger.error "[ChefsWarehouse] perform_login_steps: could not get element references"
        return
      end

      begin
        email_el.click; sleep 0.2; email_el.focus
        email_el.type(credential.username, :clear)
      rescue Ferrum::CoordinatesNotFoundError
        email_el.evaluate("this.scrollIntoView({ block: 'center' })")
        sleep 0.3; email_el.click
        email_el.type(credential.username, :clear)
      end
      sleep 0.5

      begin
        password_el.click; sleep 0.2; password_el.focus
        password_el.type(credential.password, :clear)
      rescue Ferrum::CoordinatesNotFoundError
        password_el.evaluate("this.scrollIntoView({ block: 'center' })")
        sleep 0.3; password_el.click
        password_el.type(credential.password, :clear)
      end
      sleep 0.5

      # Click submit
      if login_result['submitId']
        submit_el = browser.at_css("##{login_result['submitId']}")
        if submit_el
          begin
            submit_el.click
          rescue Ferrum::CoordinatesNotFoundError
            submit_el.evaluate("this.scrollIntoView({ block: 'center' })")
            sleep 0.3; submit_el.click
          end
        else
          browser.keyboard.type(:Enter)
        end
      else
        browser.keyboard.type(:Enter)
      end

      sleep 2

      # If still on login page, try Enter as fallback
      if browser.current_url.to_s.include?('/login')
        logger.info '[ChefsWarehouse] perform_login_steps: still on login page, pressing Enter'
        begin
          password_el_retry = browser.at_css("##{login_result['passwordId']}")
          password_el_retry&.focus
        rescue StandardError; nil; end
        browser.keyboard.type(:Enter)
      end

      wait_for_page_load
      sleep 5
    end

    public

    # Override scrape_catalog to use hybrid category browsing + search
    # Optimization: Skip search phase if categories yield sufficient products
    def scrape_catalog(search_terms, max_per_term: 50)
      results = []
      # Target: if we get 500+ products from categories, only do 10 strategic searches
      # Otherwise, do all searches to ensure coverage
      category_target = 500
      search_phase_limit = nil

      with_browser do
        # Login if needed
        unless restore_session && (navigate_to(BASE_URL) || true) && logged_in?
          perform_login_steps
          sleep 2
          raise AuthenticationError, 'Could not log in for catalog import' unless logged_in?

          save_session
        end

        # Phase 1: Browse categories for broad coverage
        logger.info "[ChefsWarehouse] Phase 1: Browsing #{CW_CATEGORIES.size} categories"
        CW_CATEGORIES.each do |category|
          begin
            products = browse_category(category, max: max_per_term)
            products.each { |p| p[:category] ||= category.to_s.titleize }
            results.concat(products)
            logger.info "[ChefsWarehouse] Category '#{category}': #{products.size} products (total: #{results.size})"
          rescue StandardError => e
            logger.warn "[ChefsWarehouse] Category browse failed for '#{category}': #{e.class}: #{e.message}"
          end
          rate_limit_delay
        end

        # Decide how many searches to run based on category results
        if results.size >= category_target
          # Good coverage from categories, only do strategic searches
          search_phase_limit = 10
          logger.info "[ChefsWarehouse] Categories yielded #{results.size} products (target: #{category_target}). Limiting search phase to #{search_phase_limit} terms."
        else
          logger.info "[ChefsWarehouse] Categories yielded #{results.size} products (below target #{category_target}). Running full search phase."
        end

        # Phase 2: Search terms for items missed in categories
        terms_to_search = search_phase_limit ? search_terms.first(search_phase_limit) : search_terms
        logger.info "[ChefsWarehouse] Phase 2: Searching with #{terms_to_search.size} terms"

        terms_to_search.each do |term|
          begin
            products = search_supplier_catalog(term, max: max_per_term)
            results.concat(products)
            logger.info "[ChefsWarehouse] Search '#{term}': #{products.size} products"
          rescue StandardError => e
            logger.warn "[ChefsWarehouse] Search failed for '#{term}': #{e.class}: #{e.message}"
          end
          rate_limit_delay
        end
      end

      # De-duplicate by SKU
      deduped = results.uniq { |r| r[:supplier_sku] }
      logger.info "[ChefsWarehouse] Total unique products: #{deduped.size} (from #{results.size} raw)"
      deduped
    end

    private

    # ── Field discovery ─────────────────────────────────────────────
    # Iterates an array of CSS selectors, returns the first visible element found
    def discover_field(selectors, label)
      selectors.each do |sel|
        elements = browser.css(sel)
        elements.each do |el|
          visible = begin
            el.evaluate(<<~JS)
              var s = window.getComputedStyle(this);
              s.display !== 'none' && s.visibility !== 'hidden' &&
              s.opacity !== '0' && this.offsetWidth > 0 && this.offsetHeight > 0
            JS
          rescue StandardError
            false
          end

          if visible
            logger.info "[ChefsWarehouse] Found #{label} field via '#{sel}'"
            return el
          end
        end
      rescue StandardError => e
        logger.debug "[ChefsWarehouse] Selector '#{sel}' raised: #{e.message}"
      end

      # Fallback: try to find ANY input by scanning all inputs on page
      if label.include?('email') || label.include?('username')
        fallback = begin
          browser.evaluate(<<~JS)
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
        rescue StandardError
          nil
        end

        if fallback && fallback['found']
          all_inputs = browser.css('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])')
          idx = fallback['index']
          if idx && idx < all_inputs.length
            el = all_inputs[idx]
            guess_note = fallback['isGuess'] ? ' (best guess)' : ''
            logger.info "[ChefsWarehouse] Found #{label} field via JS scan: type=#{fallback['type']}, name=#{fallback['name']}#{guess_note}"
            return el
          end
        end
      end

      if label.include?('password')
        pw_el = begin
          browser.at_css("input[type='password']")
        rescue StandardError
          nil
        end
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
      escaped_value = value.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")

      # Use JavaScript to fill the field - more robust for SPAs
      filled = begin
        browser.evaluate(<<~JS)
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
      rescue StandardError
        false
      end

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
      selector = begin
        element.evaluate(<<~JS)
          (function() {
            var el = this;
            if (el.id) return '#' + el.id;
            if (el.name) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
            if (el.type) return el.tagName.toLowerCase() + '[type="' + el.type + '"]';
            return el.tagName.toLowerCase();
          })()
        JS
      rescue StandardError
        nil
      end
      selector || 'input'
    end

    # Retry filling a field by searching for it again
    def retry_fill_by_label(label, value)
      escaped_value = value.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")

      if label.include?('email') || label.include?('username')
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
      elsif label.include?('password')
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
      current = begin
        browser.current_url.to_s.downcase
      rescue StandardError
        ''
      end
      # Only count as success if we're on a known authenticated-only page
      success_patterns = %w[/dashboard /account /my-account /orders /order-guide]
      success_patterns.any? { |p| current.include?(p) }
    end

    # ── Full page diagnostic dump ───────────────────────────────────
    def capture_page_diagnostics
      url = begin
        browser.current_url
      rescue StandardError
        'unknown'
      end
      title = begin
        browser.evaluate('document.title')
      rescue StandardError
        'unknown'
      end

      # Get all input fields on the page for debugging
      inputs_info = begin
        browser.evaluate(<<~JS)
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
      rescue StandardError
        'could not enumerate inputs'
      end

      # Get page body text snippet
      body_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 500)')
      rescue StandardError
        ''
      end

      # Get all iframes (login might be in an iframe)
      iframes_info = begin
        browser.evaluate(<<~JS)
          (function() {
            var frames = document.querySelectorAll('iframe');
            var info = [];
            for (var i = 0; i < frames.length; i++) {
              info.push({ src: frames[i].src || '', id: frames[i].id || '', name: frames[i].name || '' });
            }
            return JSON.stringify(info);
          })()
        JS
      rescue StandardError
        'none'
      end

      parts = [
        "URL: #{url}",
        "Title: '#{title}'",
        "Page inputs: #{inputs_info}",
        "Iframes: #{iframes_info}",
        "Page text: #{body_text.to_s.strip.truncate(300)}"
      ]

      parts.join(' | ')
    end

    # ── Product scraping ────────────────────────────────────────────
    def scrape_product(sku)
      navigate_to("#{BASE_URL}/product/#{sku}")

      return nil unless browser.at_css('.product-detail, .pdp-container')

      {
        supplier_sku: sku,
        supplier_name: extract_text('.product-name, h1.title'),
        current_price: extract_price(extract_text('.price, .product-price')),
        pack_size: extract_text('.pack-info, .unit-size'),
        in_stock: browser.at_css('.out-of-stock, .sold-out').nil?,
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
      products = extract_products_from_items(max) if products.empty?

      products
    end

    # Primary extraction: CW embeds JSON in hidden input[data-sku][data-object]
    def extract_products_from_data_objects(max)
      raw = begin
        browser.evaluate(<<~JS)
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
      rescue StandardError
        []
      end

      (raw || []).map do |item|
        pack = item['pack_size'].to_s.strip.presence
        product_url = item['url'].to_s.presence
        product_url = "#{BASE_URL}#{product_url}" if product_url && !product_url.start_with?('http')
        {
          supplier_sku: item['sku'],
          supplier_name: item['name'],
          current_price: item['price'].is_a?(Numeric) ? item['price'] : nil,
          pack_size: pack,
          supplier_url: product_url,
          in_stock: item['in_stock'] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    end

    # Fallback: parse visible .product-item divs
    def extract_products_from_items(max)
      raw = begin
        browser.evaluate(<<~JS)
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
      rescue StandardError
        []
      end

      (raw || []).map do |item|
        sku = item['sku']
        {
          supplier_sku: sku,
          supplier_name: item['name'],
          current_price: item['price'].is_a?(Numeric) ? item['price'] : nil,
          pack_size: item['pack'].presence,
          supplier_url: sku.present? ? "#{BASE_URL}/products/#{sku}/" : nil,
          in_stock: item['in_stock'] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    end

    # ── Checkout helpers ────────────────────────────────────────────

    def navigate_to_cart_page
      # Try the main cart URL first
      navigate_to("#{BASE_URL}/cart")
      sleep 3 # Wait for Vue SPA to render

      # Check if we're on a cart page with items
      page_text = browser.evaluate('document.body.innerText') || ''

      # If the page doesn't look like a cart, try alternate URLs
      unless page_text.match?(/\$\d+\.\d{2}/) || page_text.downcase.include?('cart') || page_text.downcase.include?('shopping')
        logger.info "[ChefsWarehouse] /cart didn't load cart content, trying /account-dashboard/cart/"
        navigate_to("#{BASE_URL}/account-dashboard/cart/")
        sleep 3
        page_text = browser.evaluate('document.body.innerText') || ''
      end

      # Log the page structure for DOM discovery
      logger.info "[ChefsWarehouse] Cart page URL: #{browser.current_url}"
      logger.info "[ChefsWarehouse] Cart page text (first 500 chars): #{page_text[0..500]}"

      # Log DOM structure for selector discovery
      dom_info = browser.evaluate(<<~JS)
        (function() {
          var info = { url: window.location.href, title: document.title };
          info.has_table = !!document.querySelector('table');
          info.has_cart_class = !!document.querySelector('[class*="cart"]');
          info.has_price = !!document.body.innerText.match(/\\$\\d+\\.\\d{2}/);
          info.buttons = Array.from(document.querySelectorAll('button, a.btn, [role="button"]'))
            .slice(0, 20)
            .map(function(b) { return { tag: b.tagName, text: b.innerText.trim().substring(0, 50), classes: b.className.substring(0, 80) }; });
          info.inputs = Array.from(document.querySelectorAll('input[type="number"]'))
            .map(function(i) { return { name: i.name, value: i.value, classes: i.className.substring(0, 80) }; });
          return info;
        })()
      JS

      logger.info "[ChefsWarehouse] Cart page DOM: #{dom_info.inspect}"
    end

    def extract_cart_data
      cart_data = browser.evaluate(<<~JS)
        (function() {
          var result = { items: [], subtotal: 0, item_count: 0, unavailable: [], raw_prices: [], badge_count: 0 };

          // === ITEM COUNT: Trust the shopping cart badge (most reliable) ===
          var cartBadge = document.querySelector('.shopping-cart-btn, .mobile-shopping-cart-btn, [class*="cart-count"]');
          if (cartBadge) {
            var badgeNum = parseInt(cartBadge.innerText.trim());
            if (!isNaN(badgeNum)) result.badge_count = badgeNum;
          }

          var pageText = document.body.innerText;

          // === SUBTOTAL: Look for labeled amounts ===
          var subtotalPatterns = [
            /subtotal[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /cart\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /estimated\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i
          ];
          for (var pattern of subtotalPatterns) {
            var match = pageText.match(pattern);
            if (match) {
              result.subtotal = parseFloat(match[1].replace(',', ''));
              break;
            }
          }

          // === CART ITEMS: Only count elements with quantity inputs ===
          // Actual cart items have qty inputs; recommendation products just have "Add to Cart" buttons
          var qtyInputs = document.querySelectorAll('input[type="number"]');
          var cartItems = [];

          qtyInputs.forEach(function(input) {
            if (input.offsetParent === null) return; // skip hidden

            // Walk up to find the containing cart item element
            var container = input.closest(
              '[class*="cart-item"], [class*="line-item"], [class*="product-row"], ' +
              'tr, li, .card, [class*="cart"] > div'
            );
            if (!container) container = input.parentElement && input.parentElement.parentElement;
            if (!container) return;

            // Skip if this container is inside a recommendation/suggested section
            var inRecommendation = container.closest('[class*="recommend"], [class*="suggest"], [class*="trending"], [class*="carousel"]');
            if (inRecommendation) return;

            var elText = container.innerText || '';
            var priceMatch = elText.match(/\\$([\\d,]+\\.\\d{2})/);
            var qty = parseInt(input.value) || 1;
            var name = elText.split('\\n')[0].trim().substring(0, 80);
            var price = priceMatch ? parseFloat(priceMatch[1].replace(',', '')) : 0;
            var sku = (container.getAttribute('data-sku') || container.getAttribute('data-product-id') || '').trim();

            var isUnavailable = elText.toLowerCase().match(/out of stock|unavailable|discontinued/);

            if (price > 0) {
              var item = { name: name, price: price, quantity: qty, sku: sku };
              cartItems.push(item);
              if (isUnavailable) result.unavailable.push(item);
            }
          });

          result.items = cartItems;
          result.raw_prices = (pageText.match(/\\$[\\d,]+\\.\\d{2}/g) || []);

          // Item count: prefer badge (most reliable), then found cart items
          result.item_count = result.badge_count || cartItems.length;

          // Subtotal: if no labeled subtotal, sum the cart items we found
          if (result.subtotal === 0 && cartItems.length > 0) {
            result.subtotal = cartItems.reduce(function(sum, item) {
              return sum + (item.price * item.quantity);
            }, 0);
          }

          // Last resort subtotal: largest dollar amount on page
          if (result.subtotal === 0 && result.raw_prices.length > 0) {
            var amounts = result.raw_prices.map(function(p) { return parseFloat(p.replace(/[\\$,]/g, '')); });
            result.subtotal = Math.max.apply(null, amounts);
          }

          return result;
        })()
      JS

      logger.info "[ChefsWarehouse] Cart extraction: badge=#{cart_data['badge_count']}, items_found=#{(cart_data['items'] || []).size}, subtotal=#{cart_data['subtotal']}"

      {
        items: cart_data['items'] || [],
        subtotal: cart_data['subtotal'] || 0,
        item_count: cart_data['item_count'] || 0,
        unavailable_items: (cart_data['unavailable'] || []).map { |i| { sku: i['sku'], name: i['name'], message: 'Out of stock' } },
        raw_prices: cart_data['raw_prices'] || []
      }
    end

    def proceed_to_checkout_page
      # Find and click checkout/proceed button using text matching (most reliable for unknown DOM)
      clicked = browser.evaluate(<<~JS)
        (function() {
          // Exclusion classes — buttons that happen to say "Submit" but aren't checkout
          var excludeClasses = ['search-button', 'clear-button', 'close-button'];

          function isExcluded(el) {
            var cls = (el.className || '').toLowerCase();
            for (var exc of excludeClasses) {
              if (cls.includes(exc)) return true;
            }
            return false;
          }

          // Phase 1: Exact text matches for common checkout buttons
          var exactTargets = ['checkout', 'proceed to checkout', 'proceed', 'place order', 'continue to checkout'];
          var elements = document.querySelectorAll('button, a.btn, a[class*="btn"], [role="button"], input[type="submit"]');

          for (var el of elements) {
            if (isExcluded(el)) continue;
            var text = (el.innerText || el.value || '').trim().toLowerCase();
            for (var target of exactTargets) {
              if (text.includes(target)) {
                el.scrollIntoView({ behavior: 'instant', block: 'center' });
                el.click();
                return { clicked: true, text: el.innerText.trim(), tag: el.tagName, method: 'exact-text' };
              }
            }
          }

          // Phase 2: CW-specific — look for a primary "Submit" button (not search/close)
          // CW's cart uses a btn-primary "Submit" button as the checkout action
          for (var el of elements) {
            if (isExcluded(el)) continue;
            var text = (el.innerText || el.value || '').trim().toLowerCase();
            var cls = (el.className || '').toLowerCase();
            if (text === 'submit' && (cls.includes('btn-primary') || cls.includes('btn-submit') || cls.includes('cart'))) {
              el.scrollIntoView({ behavior: 'instant', block: 'center' });
              el.click();
              return { clicked: true, text: el.innerText.trim(), tag: el.tagName, method: 'primary-submit', classes: el.className };
            }
          }

          // Phase 3: Any visible "Submit" button that isn't excluded
          for (var el of elements) {
            if (isExcluded(el)) continue;
            var text = (el.innerText || el.value || '').trim().toLowerCase();
            if (text === 'submit' && el.offsetParent !== null) {
              el.scrollIntoView({ behavior: 'instant', block: 'center' });
              el.click();
              return { clicked: true, text: el.innerText.trim(), tag: el.tagName, method: 'submit-fallback', classes: el.className };
            }
          }

          // Phase 4: href-based links
          var links = document.querySelectorAll('a[href*="checkout"], a[href*="order"]');
          for (var link of links) {
            if (link.offsetParent !== null) {
              link.click();
              return { clicked: true, text: link.innerText.trim(), method: 'href-match' };
            }
          }

          return { clicked: false };
        })()
      JS

      if clicked && clicked['clicked']
        logger.info "[ChefsWarehouse] Clicked checkout button: #{clicked.inspect}"
      else
        logger.warn "[ChefsWarehouse] Could not find checkout button — logging page state"
        log_page_state('checkout_button_not_found')
        raise ScrapingError, 'Could not find checkout/proceed button'
      end

      sleep 5 # Wait for checkout page to load (Vue SPA navigation)

      # Log checkout page structure for discovery
      logger.info "[ChefsWarehouse] Checkout page URL: #{browser.current_url}"
      page_text = browser.evaluate('document.body.innerText') || ''
      logger.info "[ChefsWarehouse] Checkout page text (first 500 chars): #{page_text[0..500]}"
    end

    def extract_checkout_data
      checkout_data = browser.evaluate(<<~JS)
        (function() {
          var text = document.body.innerText;
          var result = { total: 0, delivery_date: null, summary_text: text.substring(0, 1000) };

          // Extract total
          var totalPatterns = [
            /order\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /grand\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /amount\\s*due[:\\s]*\\$([\\d,]+\\.\\d{2})/i
          ];
          for (var pattern of totalPatterns) {
            var match = text.match(pattern);
            if (match) {
              result.total = parseFloat(match[1].replace(',', ''));
              break;
            }
          }

          // Extract delivery date
          var datePatterns = [
            /deliver[y]?\\s*(?:date)?[:\\s]*(\\w+ \\d{1,2},? \\d{4})/i,
            /ship\\s*(?:date)?[:\\s]*(\\w+ \\d{1,2},? \\d{4})/i,
            /estimated\\s*delivery[:\\s]*(\\w+ \\d{1,2},? \\d{4})/i,
            /(\\d{1,2}\\/\\d{1,2}\\/\\d{2,4})/
          ];
          for (var pattern of datePatterns) {
            var match = text.match(pattern);
            if (match) {
              result.delivery_date = match[1];
              break;
            }
          }

          // Capture available buttons for logging
          result.buttons = Array.from(document.querySelectorAll('button, input[type="submit"], a.btn'))
            .filter(function(b) { return b.offsetParent !== null; })
            .slice(0, 15)
            .map(function(b) { return { text: b.innerText.trim().substring(0, 50), tag: b.tagName, classes: b.className.substring(0, 80) }; });

          return result;
        })()
      JS

      logger.info "[ChefsWarehouse] Checkout data: #{checkout_data.inspect}"

      {
        total: checkout_data['total'] || 0,
        delivery_date: checkout_data['delivery_date'],
        summary_text: checkout_data['summary_text'],
        buttons: checkout_data['buttons'] || []
      }
    end

    def click_place_order_button
      clicked = browser.evaluate(<<~JS)
        (function() {
          var targets = ['place order', 'submit order', 'complete order', 'confirm order'];
          var elements = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');

          for (var el of elements) {
            var text = (el.innerText || el.value || '').trim().toLowerCase();
            for (var target of targets) {
              if (text.includes(target)) {
                el.scrollIntoView({ behavior: 'instant', block: 'center' });
                el.click();
                return { clicked: true, text: el.innerText.trim() };
              }
            }
          }

          return { clicked: false };
        })()
      JS

      raise ScrapingError, 'Could not find place order button' unless clicked && clicked['clicked']

      logger.info "[ChefsWarehouse] Clicked place order: #{clicked.inspect}"
    end

    def wait_for_order_confirmation
      start_time = Time.current
      timeout = 30

      loop do
        page_text = browser.evaluate('document.body.innerText') || ''

        # Check for confirmation indicators
        if page_text.match?(/confirmation|order\s*#|order\s*number|thank\s*you|order\s*placed/i)
          # Extract confirmation number
          conf_match = page_text.match(/(?:order\s*#?|confirmation\s*#?)[:\s]*([A-Z0-9-]+)/i)
          total_match = page_text.match(/total[:\s]*\$[\d,]+\.\d{2}/i)

          confirmation_number = conf_match ? conf_match[1] : "CW-#{Time.current.strftime('%Y%m%d%H%M%S')}"
          total = total_match ? extract_price(total_match[0]) : nil

          logger.info "[ChefsWarehouse] Order confirmed: #{confirmation_number}"

          return {
            confirmation_number: confirmation_number,
            total: total,
            delivery_date: nil
          }
        end

        # Check for errors
        if page_text.match?(/error|failed|could not|unable to/i) && !page_text.match?(/confirmation/i)
          error_text = page_text[0..200]
          raise ScrapingError, "Checkout failed: #{error_text}"
        end

        raise ScrapingError, 'Checkout confirmation timeout (30s)' if Time.current - start_time > timeout

        sleep 1
      end
    end

    def log_page_state(context)
      page_info = browser.evaluate(<<~JS)
        (function() {
          return {
            url: window.location.href,
            title: document.title,
            text_preview: document.body.innerText.substring(0, 1000),
            button_count: document.querySelectorAll('button').length,
            link_count: document.querySelectorAll('a').length,
            input_count: document.querySelectorAll('input').length
          };
        })()
      JS

      logger.info "[ChefsWarehouse] Page state (#{context}): #{page_info.inspect}"
    end
  end
end
