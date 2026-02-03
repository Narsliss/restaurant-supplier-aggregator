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
          logger.info "[PremiereProduceOne] Verification code page detected — waiting for user code"
          code = wait_for_user_code
          if code
            enter_verification_code(code)
          else
            credential.mark_failed!("Verification timed out. No code was entered.")
            raise AuthenticationError, "Verification timed out"
          end
        end

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
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

    # Not used for PPO — the login method handles code entry inline.
    # Kept for interface compatibility with TwoFactorChannel.
    def login_with_code(code)
      { success: false, error: "Use the inline verification form instead. Click Validate to start a new login." }
    end

    def logged_in?
      return true if browser.at_css(".user-menu, .account-dropdown, .logged-in, [data-user-logged-in], .my-account, .account-nav").present?

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

    # Create a 2FA request in the DB and poll for the user's code.
    # The browser stays open on the verification page while we wait.
    # Returns the code string when the user submits it, or nil on timeout.
    def wait_for_user_code
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 1000)") rescue ""
      prompt = body_text.scan(/your code.*?\./i).first || "A verification code has been sent to your email."

      # Create the 2FA request record
      request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        request_type: "login",
        two_fa_type: "email",
        prompt_message: prompt,
        status: "pending",
        expires_at: 5.minutes.from_now
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

    # Enter the verification code on the currently open code page and check the result.
    # PPO is a React SPA — React overrides the native input value setter, so we must
    # use the nativeInputValueSetter trick to update React's internal state.
    def enter_verification_code(code)
      code_input = find_2fa_code_input
      unless code_input
        credential.mark_failed!("Could not find verification code input")
        raise AuthenticationError, "Could not find verification code input"
      end

      logger.info "[PremiereProduceOne] Entering verification code into input field"

      # React-compatible value entry: use the native HTMLInputElement value setter
      # to bypass React's synthetic event system, then dispatch proper events.
      set_react_input_value(code_input, code)

      sleep 1

      # Click "Continue" to submit the code.
      # PPO is a React SPA — the previous email step's Continue button may still be in the DOM,
      # so we must click the LAST Continue button on the page (the one for the code entry step).
      continue_clicked = click_last_button_by_text("continue")
      unless continue_clicked
        # Fallback: try submitting by pressing Enter on the input
        logger.info "[PremiereProduceOne] Continue button not found, trying Enter key"
        begin
          code_input.focus
          browser.keyboard.type(:Enter)
        rescue => e
          logger.warn "[PremiereProduceOne] Enter key fallback failed: #{e.message}"
        end
      end

      sleep 5
      wait_for_page_load

      # Update the 2FA request based on the result
      request = Supplier2faRequest.where(
        supplier_credential: credential,
        status: "submitted"
      ).order(created_at: :desc).first

      if logged_in?
        save_session
        credential.mark_active!
        save_trusted_device
        request&.mark_verified!
        logger.info "[PremiereProduceOne] Verification successful — logged in!"

        # Broadcast success to the frontend
        TwoFactorChannel.broadcast_to(
          credential.user,
          { type: "code_result", success: true }
        )
      else
        body_text = browser.evaluate("document.body?.innerText?.substring(0, 2000)") rescue ""
        logger.warn "[PremiereProduceOne] Not logged in after code entry. Page text: #{body_text[0..300]}"

        error = if body_text.match?(/maximum.*attempts|too many.*attempts|try again.*minutes|rate.?limit/i)
                  rate_msg = body_text.scan(/maximum.*?minutes\.?|too many.*?minutes\.?|try again.*?minutes\.?/i).first
                  rate_msg&.strip || "Too many login attempts. Please wait and try again."
                elsif body_text.match?(/invalid|incorrect|expired|wrong/i)
                  body_text.scan(/(?:invalid|incorrect|expired|wrong)[^\n]{0,60}/i).first || "Invalid code"
                elsif two_fa_page?
                  "Code not accepted. Please try again."
                else
                  "Verification failed"
                end

        logger.warn "[PremiereProduceOne] Code rejected: #{error}"
        request&.mark_failed!

        # Check if we can retry
        remaining = request ? (Supplier2faRequest::MAX_ATTEMPTS - request.attempts) : 0

        # Broadcast failure to the frontend
        TwoFactorChannel.broadcast_to(
          credential.user,
          { type: "code_result", success: false, error: error, can_retry: remaining > 0, attempts_remaining: remaining }
        )

        credential.mark_failed!(error)
        raise AuthenticationError, error
      end
    end

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
