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
          sleep 2
          return true if logged_in?
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
          sleep 2
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

    def add_to_cart(items)
      with_browser do
        login unless logged_in?

        items.each do |item|
          navigate_to("#{BASE_URL}/products/#{item[:sku]}")

          begin
            wait_for_selector(".product-page, .product-detail", timeout: 10)
          rescue ScrapingError
            logger.warn "[PremiereProduceOne] Product page not found for SKU #{item[:sku]}"
            next
          end

          qty_field = browser.at_css("input[name='quantity'], .quantity-field, #quantity")
          if qty_field
            qty_field.focus
            qty_field.type(item[:quantity].to_s, :clear)
          end

          click(".add-to-cart, .btn-add-cart, [data-action='add-to-cart']")

          begin
            wait_for_selector(".cart-added, .success-message, .cart-updated", timeout: 5)
          rescue ScrapingError
            logger.warn "[PremiereProduceOne] No cart confirmation for SKU #{item[:sku]}"
          end

          rate_limit_delay
        end

        true
      end
    end

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
    # Product text pattern:
    #   PRODUCT NAME
    #   [price or "Special Order Item"] | Brand: BRAND | Pack Size: SIZE | ...
    #   Case • SKU
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
      sleep 3 # Wait for React to filter results

      # Extract products from the page text using JavaScript
      products_json = browser.evaluate(<<~JS)
        (function() {
          var text = document.body.innerText;
          var lines = text.split("\\n").map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });
          var products = [];

          for (var i = 0; i < lines.length; i++) {
            // Look for "Case • NNNNN" pattern which marks the end of a product block
            var skuMatch = lines[i].match(/^(?:Case|Each|Piece)\\s*[•·]\\s*(\\d{3,})$/);
            if (!skuMatch) continue;

            var sku = skuMatch[1];

            // Walk backwards to find the product name and description
            // The name is the first ALL-CAPS line before the description
            var name = null;
            var description = null;
            var price = null;
            var packSize = null;
            var brand = null;
            var unit = lines[i].match(/^(Case|Each|Piece)/)[1];
            var category = null;

            for (var j = i - 1; j >= Math.max(0, i - 5); j--) {
              var line = lines[j];

              // Skip category headers (they're in the sidebar)
              if (/^(All|BAKERY|BEVERAGE|DAIRY|FFV|FOODSERVICE|PANTRY|PRODUCE|PROTEIN|SPECIALTY|Sort:)/.test(line)) continue;
              if (/^See all \\d+ products/.test(line)) continue;
              if (/^\\d+$/.test(line)) continue; // category counts
              if (/^".*"$/.test(line)) continue; // search term echo

              // Description line with Brand/Pack Size
              if (line.includes("Brand:") || line.includes("Pack Size:")) {
                description = line;
                var brandMatch = line.match(/Brand:\\s*([^|]+)/);
                if (brandMatch) brand = brandMatch[1].trim();
                var packMatch = line.match(/Pack Size:\\s*([^|]+)/);
                if (packMatch) packSize = packMatch[1].trim();
                var priceMatch = line.match(/\\$([\\d,.]+)/);
                if (priceMatch) price = parseFloat(priceMatch[1].replace(",", ""));
                continue;
              }

              // Product name — typically ALL CAPS or mixed case, before the description.
              // Skip lines that look like continuation descriptions (start lowercase,
              // contain "Storage Instructions", or are very long paragraphs).
              if (!name && line.length > 2 && line.length < 120 && !line.includes("|")
                  && !line.startsWith("Storage") && !line.startsWith("An ")
                  && !line.startsWith("A ") && !line.startsWith("The ")
                  && !line.startsWith("Tender ") && !line.startsWith("Made ")
                  && !line.startsWith("Pre-Order") && !line.startsWith("Variable")
                  && !/^[a-z]/.test(line)) {
                name = line;
                break;
              }
            }

            if (name && sku) {
              products.push({
                sku: sku,
                name: name,
                price: price,
                pack_size: packSize ? (unit + " - " + packSize) : unit,
                brand: brand,
                in_stock: !(description || "").includes("Special Order Item")
              });
            }

            if (products.length >= #{max}) break;
          }

          return JSON.stringify(products);
        })()
      JS

      items = JSON.parse(products_json) rescue []
      logger.info "[PremiereProduceOne] Parsed #{items.size} products for '#{term}' from page text"

      items.map do |item|
        {
          supplier_sku: item["sku"],
          supplier_name: item["name"].to_s.truncate(255),
          current_price: item["price"],
          pack_size: item["pack_size"],
          supplier_url: nil,
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
