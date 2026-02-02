module Scrapers
  class PremiereProduceOneScraper < BaseScraper
    BASE_URL = "https://premierproduceone.pepr.app".freeze
    LOGIN_URL = "#{BASE_URL}/".freeze
    ORDER_MINIMUM = 0.00

    def login
      with_browser do
        navigate_to(BASE_URL)

        if restore_session
          browser.refresh
          sleep 2
          return true if logged_in?
        end

        perform_login_steps

        # PPO always requires a verification code (passwordless auth)
        if two_fa_page?
          logger.info "[PremiereProduceOne] Verification code page detected"
          initiate_2fa_request!("login")
          # ^ raises TwoFactorRequired — browser will be cleaned up by ensure block
        end

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          # Check for rate limiting or other errors in page text
          body_text = browser.evaluate("document.body?.innerText?.substring(0, 2000)") rescue ""
          if body_text.match?(/maximum.*attempts|too many.*attempts|try again.*minutes|rate.?limit/i)
            error_msg = body_text.scan(/maximum.*?minutes\.?|too many.*?minutes\.?|try again.*?minutes\.?/i).first || "Too many login attempts. Please wait and try again."
            credential.mark_failed!(error_msg.strip)
            raise AuthenticationError, error_msg.strip
          end

          error_msg = extract_text(".error, .alert-error, .login-error, .error-message, .alert-danger")
          error_msg ||= body_text.scan(/(?:invalid|error|failed|incorrect)[^\n]{0,80}/i).first
          error_msg ||= "Login failed"
          credential.mark_failed!(error_msg.strip)
          raise AuthenticationError, error_msg.strip
        end
      end
    end

    # Login with a 2FA code — called when resuming after user enters code.
    # Re-performs the login steps (enter email → Continue) which triggers a new code,
    # but the user should already have a code from the initial attempt.
    # PPO sends the code via email, so re-triggering may send a new one.
    def login_with_code(code)
      with_browser do
        # Re-login to get back to the verification page
        perform_login_steps

        # Wait for 2FA prompt
        sleep 2
        unless two_fa_page?
          if logged_in?
            save_session
            credential.mark_active!
            return { success: true }
          end
          return { success: false, error: "Verification page not found after login" }
        end

        # Find the code input and enter the code
        code_input = find_2fa_code_input
        unless code_input
          return { success: false, error: "Could not find verification code input" }
        end

        begin
          code_input.focus
          code_input.type(code, :clear)
        rescue => e
          code_input.evaluate("this.value = '#{code}'")
          code_input.evaluate("this.dispatchEvent(new Event('input', { bubbles: true }))")
        end

        sleep 1

        # PPO uses a "Continue" button to submit the code
        click_button_by_text("continue")
        sleep 5
        wait_for_page_load

        if logged_in?
          save_session
          credential.mark_active!
          save_trusted_device
          { success: true }
        else
          # Check for error messages
          body_text = browser.evaluate("document.body?.innerText?.substring(0, 2000)") rescue ""
          if body_text.match?(/invalid|incorrect|expired|wrong/i)
            error = body_text.scan(/(?:invalid|incorrect|expired|wrong)[^\n]{0,60}/i).first || "Invalid code"
            { success: false, error: error.strip }
          elsif two_fa_page?
            { success: false, error: "Code not accepted. Please try again." }
          else
            { success: false, error: "Verification failed" }
          end
        end
      end
    end

    def logged_in?
      # Check for common logged-in indicators
      return true if browser.at_css(".user-menu, .account-dropdown, .logged-in, [data-user-logged-in], .my-account, .account-nav").present?

      # Check page text (exclude login/2FA pages)
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 3000)") rescue ""
      return false if body_text.match?(/enter.*code|verification.*code|one.?time|otp|sign in|log in/i)
      return true if body_text.match?(/my account|sign out|log ?out|my orders|order guide|dashboard/i)

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

      # Step 3: Enter email in the email input
      email_input = browser.at_css("input[type='email']")
      if email_input
        begin
          email_input.focus
          email_input.type(credential.username, :clear)
        rescue => e
          email_input.evaluate("this.value = '#{credential.username.gsub("'", "\\\\'")}'")
          email_input.evaluate("this.dispatchEvent(new Event('input', { bubbles: true }))")
        end
      else
        logger.warn "[PremiereProduceOne] Email input not found on login page"
        raise AuthenticationError, "Could not find email input on login page"
      end

      sleep 1

      # Step 4: Click Continue to submit email and trigger verification code
      click_button_by_text("continue")
      sleep 3
      wait_for_page_load
    end

    private

    def search_supplier_catalog(term, max: 20)
      encoded = CGI.escape(term)
      navigate_to("#{BASE_URL}/search?q=#{encoded}")
      sleep 2

      products = []
      items = browser.css(".product-card, .product-item, .product-tile, .search-result-item")

      items.first(max).each do |item|
        name = item.at_css(".product-title, .product-name, h3, h4")&.text&.strip
        next if name.blank?

        price_text = item.at_css(".price, .product-price, .current-price")&.text
        price = extract_price(price_text) if price_text

        href = item.at_css("a[href*='/products/']")&.attribute("href").to_s
        sku = item.attribute("data-sku").to_s.presence
        sku ||= item.at_css("[data-sku]")&.attribute("data-sku").to_s.presence
        sku ||= href.scan(%r{/products/([^/?#]+)}).flatten.first
        sku ||= name.parameterize
        next if sku.blank?

        pack_size = item.at_css(".pack-size, .product-unit")&.text&.strip

        product_url = href.presence
        product_url = "#{BASE_URL}#{product_url}" if product_url && !product_url.start_with?("http")
        product_url ||= "#{BASE_URL}/products/#{sku}" if sku.present?

        products << {
          supplier_sku: sku,
          supplier_name: name.truncate(255),
          current_price: price,
          pack_size: pack_size,
          supplier_url: product_url,
          in_stock: item.at_css(".out-of-stock, .unavailable, .sold-out").nil?,
          category: nil,
          scraped_at: Time.current
        }
      rescue => e
        logger.debug "[PremiereProduceOne] Failed to extract catalog item: #{e.message}"
      end

      products
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
      # PPO-specific: check for the code input with placeholder "Code"
      return true if browser.at_css("input[placeholder='Code']")

      # Check page text for PPO's "Verification code" heading
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 3000)") rescue ""
      return true if body_text.include?("Verification code")
      return true if body_text.match?(/code.*been sent|enter.*code|verification.*code/i)
      return true if body_text.match?(/we.?(?:sent|texted|emailed).*code/i)
      return true if body_text.match?(/check your (?:phone|email|text)/i)

      # Generic 2FA input selectors
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
      # PPO-specific: input with placeholder "Code"
      el = browser.at_css("input[placeholder='Code']")
      return el if el

      # Try specific 2FA input selectors
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

      # Fallback: find a visible text input that looks like a code field
      browser.css("input[type='text'], input[type='tel'], input[type='number']").each do |input|
        placeholder = input.evaluate("this.placeholder || ''") rescue ""
        next if placeholder.match?(/email|password|search|phone/i)
        return input if placeholder.match?(/code|otp|verify|token/i)
      end

      # Last resort: first visible text input
      browser.at_css("input[type='text']")
    end

    # Create a 2FA request, broadcast to user via ActionCable, and raise TwoFactorRequired
    def initiate_2fa_request!(operation_type)
      # Get the prompt message from the page
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 1000)") rescue ""
      prompt = body_text.scan(/your code.*?\./i).first || "A verification code has been sent to your email."

      request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        request_type: operation_type,
        two_fa_type: "email",
        prompt_message: prompt,
        status: "pending",
        expires_at: 5.minutes.from_now
      )

      credential.update!(two_fa_enabled: true, two_fa_type: "email")

      # Broadcast to user's browser via ActionCable
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

      raise Authentication::TwoFactorHandler::TwoFactorRequired.new(
        request_id: request.id,
        two_fa_type: :email,
        prompt_message: prompt,
        session_token: request.session_token
      )
    end

    # Click a button by its visible text (case-insensitive exact match)
    def click_button_by_text(text)
      js = "(function() { var btns = document.querySelectorAll('button, [role=\"button\"]'); for (var i = 0; i < btns.length; i++) { if (btns[i].innerText.trim().toLowerCase() === '#{text.downcase}') { btns[i].click(); return true; } } return false; })()"
      result = browser.evaluate(js) rescue false
      unless result
        logger.debug "[PremiereProduceOne] Button '#{text}' not found"
      end
      result
    end

    def save_trusted_device
      # Look for "remember this device" or "trust this browser" checkbox
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

      # Also look for a "remember device" button (some sites use a button instead)
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
