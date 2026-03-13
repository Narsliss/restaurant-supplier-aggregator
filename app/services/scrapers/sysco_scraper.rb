module Scrapers
  class SyscoScraper < BaseScraper
    BASE_URL = 'https://shop.sysco.com'.freeze
    LOGIN_URL = 'https://shop.sysco.com/auth/login'.freeze
    ORDER_MINIMUM = 0.00 # Unknown — will be determined during testing

    LOGGED_IN_SELECTORS = [
      "a[href*='account']", "a[href*='logout']", "a[href*='sign-out']",
      '.account-menu', '.user-nav', '.user-menu',
      "[data-testid='user-menu']", "[data-testid='account']",
      "button[aria-label*='account']", "button[aria-label*='Account']"
    ].freeze

    # ----------------------------------------------------------------
    # Browser setup — stealth mode (Sysco is enterprise-scale, expect WAF)
    # ----------------------------------------------------------------

    def with_browser
      @browser = Ferrum::Browser.new(**build_stealth_browser_opts)
      setup_network_interception(@browser)
      inject_stealth_scripts(@browser)

      yield(browser)
    ensure
      browser&.quit
    end

    # ----------------------------------------------------------------
    # Public API — Authentication
    # ----------------------------------------------------------------

    def login
      with_browser do
        navigate_to(BASE_URL)

        if restore_session
          browser.refresh
          sleep 2
          if logged_in?
            save_session
            return true
          end
          logger.info '[Sysco] Session restore failed, doing fresh login'
        end

        perform_login_steps
        sleep 3

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          diagnose_login_failure
          raise AuthenticationError, 'Login completed but not authenticated'
        end
      end
    end

    def logged_in?
      current_url = begin
        browser.current_url.to_s
      rescue StandardError
        ''
      end

      # shop.sysco.com/app/ is the authenticated SPA
      return true if current_url.include?('shop.sysco.com/app')

      # Check for user account UI elements
      LOGGED_IN_SELECTORS.any? do |sel|
        browser.at_css(sel)
      rescue StandardError
        false
      end
    end

    def soft_refresh
      with_browser do
        if restore_session
          navigate_to(BASE_URL)
          sleep 3
          apply_stealth
          if logged_in?
            save_session
            return true
          end
        end
        false
      end
    end

    # ----------------------------------------------------------------
    # Public API — Catalog & Lists (stubs — need DOM inspection)
    # ----------------------------------------------------------------

    def scrape_catalog(search_terms, max_per_term: 20, &on_batch)
      logger.warn '[Sysco] Catalog scraping not yet implemented — returning empty results'
      # TODO: Implement after inspecting shop.sysco.com DOM structure
      # Likely pattern: search bar → results grid → extract product cards
      []
    end

    def search_supplier_catalog(term, max: 20)
      logger.warn "[Sysco] Catalog search not yet implemented for term: #{term}"
      []
    end

    def scrape_supplier_lists
      logger.warn '[Sysco] Order guide scraping not yet implemented'
      # TODO: Implement after inspecting shop.sysco.com order guide pages
      []
    end

    # ----------------------------------------------------------------
    # Public API — Ordering (out of scope)
    # ----------------------------------------------------------------

    def scrape_prices(product_skus)
      raise NotImplementedError, 'Sysco price scraping not yet implemented'
    end

    def add_to_cart(items, delivery_date: nil)
      raise NotImplementedError, 'Sysco ordering not yet implemented'
    end

    def checkout(dry_run: false)
      raise NotImplementedError, 'Sysco ordering not yet implemented'
    end

    private

    # ----------------------------------------------------------------
    # Login flow — hybrid password + optional MFA
    # ----------------------------------------------------------------

    def perform_login_steps
      logger.info "[Sysco] Starting login for #{credential.username}"

      # Step 1: Navigate to shop.sysco.com/auth/login
      # This is the direct login page with email + password on one form.
      # (secure.sysco.com redirects here anyway, so skip the redirect.)
      navigate_to(LOGIN_URL)
      sleep 3
      apply_stealth

      log_page_state('After navigating to login page')

      # Step 2: Fill the email/username field
      email_filled = fill_login_email
      unless email_filled
        diagnose_login_failure
        raise AuthenticationError, 'Could not find or fill email field on shop.sysco.com/auth/login'
      end
      logger.info '[Sysco] Email entered'
      sleep 1

      # Step 3: Fill password field (both fields visible on same page)
      password_filled = fill_login_password
      unless password_filled
        diagnose_login_failure
        raise AuthenticationError, 'Could not find or fill password field'
      end
      logger.info '[Sysco] Password entered'

      # Step 4: Check for "remember me" and submit
      check_remember_me
      click_login_submit
      logger.info '[Sysco] Login form submitted, waiting for response...'
      sleep 5

      # Step 5: Check what happened — success, MFA, or error
      log_page_state('After login submit')

      # Check if we're already logged in (no MFA)
      if logged_in?
        logger.info '[Sysco] Login successful (no MFA)'
        return
      end

      # Check for login errors before checking MFA
      detect_login_errors

      # Check for MFA prompt (optional — some Sysco accounts have it, some don't)
      if handle_mfa_if_prompted
        logger.info '[Sysco] MFA completed successfully'
        sleep 3

        # Wait for redirect to shop.sysco.com after MFA
        wait_for_post_login_redirect
        return
      end

      # Neither logged in nor MFA — wait a bit more and check again
      sleep 5
      if logged_in?
        logger.info '[Sysco] Login successful (delayed redirect)'
        return
      end

      # Still not logged in — something went wrong
      diagnose_login_failure
      raise AuthenticationError, 'Login failed — not authenticated after password submission and MFA check'
    end

    # Fill the email/username field on the login page
    def fill_login_email
      # Try multiple selectors — Sysco may use various input patterns
      email_selectors = [
        'input[type="email"]',
        'input[name="email"]',
        'input[name="username"]',
        'input[name="loginfmt"]',        # Microsoft/Azure AD
        'input[name="identifier"]',
        'input#signInName',               # Azure AD B2C
        'input#signInName-facade',        # Azure AD B2C facade
        'input#i0116',                    # Microsoft login
        'input[autocomplete="username"]',
        'input[autocomplete="email"]'
      ]

      field = nil
      email_selectors.each do |sel|
        field = browser.at_css(sel) rescue nil
        if field
          logger.info "[Sysco] Found email field: #{sel}"
          break
        end
      end

      return false unless field

      # Simulate real typing character-by-character to satisfy bot detection.
      # Many enterprise login forms (Sysco included) keep the Next button
      # disabled until they see keydown/keypress/keyup events per character.
      # Setting value + dispatching input/change alone is not enough.
      browser.evaluate(<<~JS)
        (function() {
          var selectors = #{email_selectors.to_json};
          var el = null;
          for (var i = 0; i < selectors.length; i++) {
            el = document.querySelector(selectors[i]);
            if (el && el.offsetHeight > 0) break;
            el = null;
          }
          if (!el) return false;

          el.focus();
          el.click();
          el.value = '';
          el.dispatchEvent(new Event('focus', { bubbles: true }));

          var chars = #{credential.username.to_json}.split('');
          chars.forEach(function(char) {
            el.dispatchEvent(new KeyboardEvent('keydown',  { key: char, code: 'Key' + char.toUpperCase(), bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keypress', { key: char, code: 'Key' + char.toUpperCase(), bubbles: true }));

            // Build value character by character using native setter
            var nativeSetter = Object.getOwnPropertyDescriptor(
              window.HTMLInputElement.prototype, 'value'
            ).set;
            nativeSetter.call(el, el.value + char);

            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keyup', { key: char, code: 'Key' + char.toUpperCase(), bubbles: true }));
          });

          el.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })()
      JS
    end

    # Fill the password field (on the same page as email for shop.sysco.com/auth/login)
    def fill_login_password
      password_selectors = [
        'input[type="password"]',
        'input[name="password"]',
        'input[name="passwd"]',
        'input#passwordInput',
        'input#i0118',
        'input[autocomplete="current-password"]'
      ]

      # Brief wait — both fields should be on the page already,
      # but give the SPA a moment to finish rendering
      field = nil
      5.times do |attempt|
        password_selectors.each do |sel|
          candidate = browser.at_css(sel) rescue nil
          if candidate
            visible = browser.evaluate("(function() { var el = document.querySelector('#{sel}'); return el && el.offsetHeight > 0; })()")
            if visible
              field = candidate
              logger.info "[Sysco] Found password field: #{sel} (attempt #{attempt + 1})"
              break
            end
          end
        end
        break if field
        sleep 1
      end

      return false unless field

      # Simulate real typing character-by-character (same as email field).
      # The login form keeps the submit button disabled without keystroke events.
      browser.evaluate(<<~JS)
        (function() {
          var selectors = #{password_selectors.to_json};
          var el = null;
          for (var i = 0; i < selectors.length; i++) {
            el = document.querySelector(selectors[i]);
            if (el && el.offsetHeight > 0) break;
            el = null;
          }
          if (!el) return false;

          el.focus();
          el.click();
          el.value = '';
          el.dispatchEvent(new Event('focus', { bubbles: true }));

          var chars = #{credential.password.to_json}.split('');
          chars.forEach(function(char) {
            el.dispatchEvent(new KeyboardEvent('keydown',  { key: char, bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keypress', { key: char, bubbles: true }));

            var nativeSetter = Object.getOwnPropertyDescriptor(
              window.HTMLInputElement.prototype, 'value'
            ).set;
            nativeSetter.call(el, el.value + char);

            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keyup', { key: char, bubbles: true }));
          });

          el.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })()
      JS
    end

    # Click the "Next" button after entering email (advances to password step).
    # Waits for the button to become enabled — enterprise login forms often
    # keep it disabled until their JS validates the email field.
    def click_next_button
      clicked = false
      8.times do |attempt|
        clicked = browser.evaluate(<<~JS)
          (function() {
            // Try common "Next" button patterns
            var selectors = [
              "button#next",
              "button[type='submit']",
              "input[type='submit']",
              "button#idSIButton9"
            ];
            for (var i = 0; i < selectors.length; i++) {
              var btn = document.querySelector(selectors[i]);
              if (btn && btn.offsetHeight > 0 && !btn.disabled) { btn.click(); return true; }
            }

            // Fallback: find button by text content
            var buttons = document.querySelectorAll('button, input[type="submit"], a[role="button"]');
            for (var i = 0; i < buttons.length; i++) {
              var text = (buttons[i].innerText || buttons[i].value || '').trim().toLowerCase();
              if (['next', 'continue', 'sign in', 'log in'].includes(text) && !buttons[i].disabled) {
                buttons[i].click();
                return true;
              }
            }
            return false;
          })()
        JS
        break if clicked
        logger.info "[Sysco] Next button not yet enabled, waiting... (attempt #{attempt + 1}/8)"
        sleep 1
      end

      unless clicked
        logger.warn '[Sysco] Could not find Next button — trying Enter key on email field'
        browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('input[type="email"], input[type="text"]');
            for (var i = 0; i < inputs.length; i++) {
              if (inputs[i].offsetHeight > 0) {
                inputs[i].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
                inputs[i].dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', bubbles: true }));
                inputs[i].dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true }));
                return true;
              }
            }
            return false;
          })()
        JS
      end
    end

    # Click the login/submit button (after password is filled).
    # Waits for the button to become enabled, same as click_next_button.
    def click_login_submit
      clicked = false
      8.times do |attempt|
        clicked = browser.evaluate(<<~JS)
          (function() {
            // Try common submit button patterns
            var selectors = [
              "button[type='submit']",
              "input[type='submit']",
              "button#next",
              "button#idSIButton9",
              "button.btn-primary",
              "button[data-testid='submit']"
            ];
            for (var i = 0; i < selectors.length; i++) {
              var btn = document.querySelector(selectors[i]);
              if (btn && btn.offsetHeight > 0 && !btn.disabled) { btn.click(); return true; }
            }

            // Fallback: find button by text
            var buttons = document.querySelectorAll('button, input[type="submit"], a[role="button"]');
            for (var i = 0; i < buttons.length; i++) {
              var text = (buttons[i].innerText || buttons[i].value || '').trim().toLowerCase();
              if (['sign in', 'log in', 'login', 'submit', 'next', 'continue'].includes(text) && !buttons[i].disabled) {
                buttons[i].click();
                return true;
              }
            }
            return false;
          })()
        JS
        break if clicked
        logger.info "[Sysco] Submit button not yet enabled, waiting... (attempt #{attempt + 1}/8)"
        sleep 1
      end

      unless clicked
        logger.warn '[Sysco] Could not find enabled submit button — trying Enter key on password field'
        browser.evaluate(<<~JS)
          (function() {
            var el = document.querySelector('input[type="password"]');
            if (el) {
              el.dispatchEvent(new KeyboardEvent('keydown',  { key: 'Enter', code: 'Enter', bubbles: true }));
              el.dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', bubbles: true }));
              el.dispatchEvent(new KeyboardEvent('keyup',    { key: 'Enter', code: 'Enter', bubbles: true }));
            }
          })()
        JS
      end
    end

    # ----------------------------------------------------------------
    # MFA handling — optional, detected dynamically after password
    # ----------------------------------------------------------------

    def handle_mfa_if_prompted
      mfa_info = detect_mfa_prompt
      return false unless mfa_info

      logger.info "[Sysco] MFA detected: #{mfa_info[:type]} — #{mfa_info[:message]}"

      # Create a 2FA request for the user to submit their code
      tfa_request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        request_type: 'login',
        status: 'pending',
        prompt_message: mfa_info[:message],
        expires_at: 5.minutes.from_now
      )
      logger.info "[Sysco] Created 2FA request ##{tfa_request.id}, waiting for code..."
      credential.update!(two_fa_enabled: true, status: 'pending')

      # Broadcast via ActionCable so the global 2FA modal appears
      TwoFactorChannel.broadcast_to(
        credential.user,
        {
          type: 'two_fa_required',
          request_id: tfa_request.id,
          session_token: tfa_request.session_token,
          supplier_name: 'Sysco',
          two_fa_type: mfa_info[:type].to_s,
          prompt_message: mfa_info[:message],
          expires_at: tfa_request.expires_at.iso8601
        }
      )

      # Poll for user to enter the code via the web UI
      code = poll_for_2fa_code(tfa_request, timeout: 300)

      unless code
        tfa_request.update!(status: 'expired')
        raise AuthenticationError, 'Verification code was not entered in time'
      end

      # Enter the code
      logger.info '[Sysco] Entering MFA code...'
      enter_mfa_code(code)
      sleep 5

      # Verify success
      if detect_mfa_prompt
        tfa_request.update!(status: 'failed')
        raise AuthenticationError, 'MFA verification failed — still on code entry page'
      end

      # Check for error messages
      page_text = browser.evaluate('document.body?.innerText?.substring(0, 1000)') rescue ''
      if page_text.match?(/wrong.*code|incorrect.*code|invalid.*code/i)
        tfa_request.update!(status: 'failed')
        raise AuthenticationError, 'MFA verification failed: wrong code entered'
      end

      tfa_request.update!(status: 'verified')
      logger.info '[Sysco] MFA code accepted'
      true
    end

    # Detect if the current page is showing an MFA/verification code prompt
    def detect_mfa_prompt
      page_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 3000)')
      rescue StandardError
        ''
      end
      return nil if page_text.blank?

      # Check for common MFA keywords
      mfa_keywords = /verification\s*code|enter\s*(the\s*)?code|multi.?factor|one.?time\s*pass|mfa|two.?factor|security\s*code/i
      return nil unless page_text.match?(mfa_keywords)

      # Confirm there's actually a code input field visible
      has_code_input = browser.evaluate(<<~JS)
        (function() {
          // Look for code input fields (single field or multi-digit)
          var inputs = document.querySelectorAll('input[type="text"], input[type="tel"], input[type="number"]');
          for (var i = 0; i < inputs.length; i++) {
            var el = inputs[i];
            if (el.offsetHeight > 0) {
              var name = (el.name || '').toLowerCase();
              var id = (el.id || '').toLowerCase();
              var placeholder = (el.placeholder || '').toLowerCase();
              var label = (el.getAttribute('aria-label') || '').toLowerCase();
              if (name.match(/code|otp|token|verify|mfa/) ||
                  id.match(/code|otp|token|verify|mfa/) ||
                  placeholder.match(/code|enter|digit|verify/) ||
                  label.match(/code|verify|otp/) ||
                  el.maxLength == 1 || el.maxLength == 6) {
                return true;
              }
            }
          }
          return false;
        })()
      JS
      return nil unless has_code_input

      # Determine MFA type from page content
      mfa_type = if page_text.match?(/text.*message|sms|phone/i)
                   'sms'
                 elsif page_text.match?(/email|inbox/i)
                   'email'
                 else
                   'unknown'
                 end

      # Extract the prompt message
      message = if page_text.match?(/sent.*(?:to|at)\s+(\S+@\S+|\(\d{3}\)\s*\d{3}.?\d{4}|\d{3}.?\d{3}.?\d{4})/i)
                  "Sysco has sent a verification code. #{$&}"
                else
                  "Sysco requires a verification code. Please check your email or phone and enter the code."
                end

      { type: mfa_type, message: message }
    end

    # Enter an MFA code — handles both single-field and multi-digit-field patterns
    def enter_mfa_code(code)
      digits = code.to_s.gsub(/\D/, '').chars

      # Check for multi-field pattern (individual digit inputs like #code1-#code6)
      multi_field = browser.evaluate(<<~JS)
        (function() {
          // Check for numbered code fields
          for (var i = 1; i <= 8; i++) {
            var el = document.querySelector('#code' + i) ||
                     document.querySelector('[name="code' + i + '"]') ||
                     document.querySelector('[data-index="' + (i-1) + '"]');
            if (el && el.offsetHeight > 0) return 'multi';
          }
          // Check for a cluster of maxLength=1 inputs
          var singles = document.querySelectorAll('input[maxlength="1"]');
          if (singles.length >= 4) return 'single_char';
          return 'single_field';
        })()
      JS

      case multi_field
      when 'multi'
        # Individual digit fields (#code1, #code2, etc.)
        digits.each_with_index do |digit, i|
          browser.evaluate(<<~JS)
            (function() {
              var el = document.querySelector('#code#{i + 1}') ||
                       document.querySelector('[name="code#{i + 1}"]') ||
                       document.querySelector('[data-index="#{i}"]');
              if (!el) return;
              el.focus();
              var nativeSetter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
              ).set;
              nativeSetter.call(el, '#{digit}');
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            })()
          JS
          sleep 0.2
        end

      when 'single_char'
        # Multiple maxLength=1 inputs in sequence
        browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('input[maxlength="1"]');
            var digits = #{digits.to_json};
            for (var i = 0; i < Math.min(inputs.length, digits.length); i++) {
              inputs[i].focus();
              var nativeSetter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
              ).set;
              nativeSetter.call(inputs[i], digits[i]);
              inputs[i].dispatchEvent(new Event('input', { bubbles: true }));
              inputs[i].dispatchEvent(new Event('change', { bubbles: true }));
            }
          })()
        JS

      else
        # Single code field — enter the whole code at once
        full_code = digits.join
        browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('input[type="text"], input[type="tel"], input[type="number"]');
            for (var i = 0; i < inputs.length; i++) {
              var el = inputs[i];
              var name = (el.name || '').toLowerCase();
              var id = (el.id || '').toLowerCase();
              var placeholder = (el.placeholder || '').toLowerCase();
              if (el.offsetHeight > 0 && (
                  name.match(/code|otp|token|verify/) ||
                  id.match(/code|otp|token|verify/) ||
                  placeholder.match(/code|enter|digit|verify/) ||
                  el.maxLength == 6 || el.maxLength == 8)) {
                el.focus();
                var nativeSetter = Object.getOwnPropertyDescriptor(
                  window.HTMLInputElement.prototype, 'value'
                ).set;
                nativeSetter.call(el, #{full_code.to_json});
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
              }
            }
            return false;
          })()
        JS
      end

      # Try to submit the code form
      sleep 1
      browser.evaluate(<<~JS)
        (function() {
          var btns = document.querySelectorAll('button, input[type="submit"]');
          for (var i = 0; i < btns.length; i++) {
            var text = (btns[i].innerText || btns[i].value || '').trim().toLowerCase();
            if (['verify', 'submit', 'continue', 'confirm', 'next'].includes(text)) {
              btns[i].click();
              return true;
            }
          }
          // Fallback: click the first visible submit button
          var submit = document.querySelector("button[type='submit']");
          if (submit && submit.offsetHeight > 0) { submit.click(); return true; }
          return false;
        })()
      JS
    end

    # Poll for user-submitted 2FA code (same pattern as US Foods)
    def poll_for_2fa_code(tfa_request, timeout: 300)
      start_time = Time.current
      loop do
        tfa_request.reload
        if %w[submitted verified].include?(tfa_request.status) && tfa_request.code_submitted.present?
          return tfa_request.code_submitted
        end
        return nil if tfa_request.status == 'cancelled'
        return nil if tfa_request.status == 'failed'
        return nil if tfa_request.status == 'expired'
        return nil if Time.current - start_time > timeout

        sleep 2
      end
    end

    # Detect login error messages on the page
    def detect_login_errors
      page_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 2000)')
      rescue StandardError
        ''
      end

      error_patterns = [
        /invalid.*(?:email|password|credentials)/i,
        /account.*(?:locked|disabled|suspended)/i,
        /incorrect.*password/i,
        /username.*not\s*found/i,
        /login.*failed/i,
        /access.*denied/i
      ]

      error_patterns.each do |pattern|
        if page_text.match?(pattern)
          raise AuthenticationError, "Login failed: #{page_text.match(pattern)[0]}"
        end
      end
    end

    # Wait for redirect to shop.sysco.com after successful auth
    def wait_for_post_login_redirect(timeout: 20)
      start_time = Time.current
      loop do
        current = begin
          browser.current_url
        rescue StandardError
          ''
        end
        return true if current.include?('shop.sysco.com')

        if Time.current - start_time > timeout
          logger.warn "[Sysco] Post-login redirect timed out (stuck at: #{current})"
          return false
        end

        sleep 1
      end
    end

    # ----------------------------------------------------------------
    # Stealth browser setup (adapted from US Foods)
    # ----------------------------------------------------------------

    def build_stealth_browser_opts
      ua = if ENV['BROWSER_PATH'].present? || Rails.env.production?
             'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
           else
             'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
           end

      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'

      opts = {
        headless: headless_mode ? 'new' : false,
        timeout: 60,
        process_timeout: 60,
        window_size: [1280, 720],
        browser_options: {
          "no-sandbox": true,
          "disable-gpu": true,
          "disable-dev-shm-usage": true,
          "disable-blink-features": 'AutomationControlled',
          "user-agent": ua,
          "disable-features": 'AutomationControlled,TranslateUI',
          "excludeSwitches": 'enable-automation',
          "no-first-run": true,
          "no-default-browser-check": true,
          "disable-component-update": true,
          "disable-session-crashed-bubble": true,
          "disable-extensions": true,
          "disable-default-apps": true,
          "disable-translate": true,
          "disable-sync": true,
          "disable-background-timer-throttling": true,
          "disable-renderer-backgrounding": true,
          "disable-backgrounding-occluded-windows": true,
          "js-flags": '--max-old-space-size=256 --lite-mode',
          "renderer-process-limit": 1,
          "disable-software-rasterizer": true,
          "disable-image-loading": false
        }
      }
      opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?
      opts
    end

    def setup_network_interception(browser_instance)
      browser_instance.network.intercept
      browser_instance.on(:request) do |request|
        url = request.url
        if url.match?(/\.(jpg|jpeg|png|gif|webp|svg|ico|woff|woff2|ttf|eot)(\?|$)/i) ||
           url.include?('adobedtm.com') ||
           url.include?('analytics') ||
           url.include?('google-analytics') ||
           url.include?('googletagmanager')
          request.abort
        else
          request.continue
        end
      end
    rescue StandardError => e
      logger.warn "[Sysco] Network interception setup failed: #{e.message}"
    end

    def inject_stealth_scripts(browser_instance)
      stealth_js = <<~JS
        Object.defineProperty(navigator, 'webdriver', {get: () => false});
        Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
        Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
        if (!window.chrome) window.chrome = {};
        if (!window.chrome.runtime) window.chrome.runtime = {};
      JS
      browser_instance.evaluate_on_new_document(stealth_js)
    rescue StandardError => e
      logger.warn "[Sysco] CDP stealth injection failed: #{e.message}"
    end

    def apply_stealth
      browser.evaluate(<<~JS)
        (function() {
          Object.defineProperty(navigator, 'webdriver', {get: () => false});
          Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
          Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
          if (!window.chrome) window.chrome = {};
          if (!window.chrome.runtime) window.chrome.runtime = {};
          var getParameter = WebGLRenderingContext.prototype.getParameter;
          WebGLRenderingContext.prototype.getParameter = function(parameter) {
            if (parameter === 37445) return 'Intel Inc.';
            if (parameter === 37446) return 'Intel Iris OpenGL Engine';
            return getParameter.call(this, parameter);
          };
        })()
      JS
    rescue StandardError
      nil
    end

    # ----------------------------------------------------------------
    # Session management (SPA — save cookies + localStorage + sessionStorage)
    # ----------------------------------------------------------------

    def save_session
      cookies = browser.cookies.all.transform_values(&:to_h)
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
      session_storage = begin
        browser.evaluate(<<~JS)
          (function() {
            var data = {};
            for (var i = 0; i < sessionStorage.length; i++) {
              var key = sessionStorage.key(i);
              data[key] = sessionStorage.getItem(key);
            }
            return data;
          })()
        JS
      rescue StandardError
        {}
      end

      session_blob = {
        cookies: cookies,
        local_storage: local_storage,
        session_storage: session_storage
      }.to_json

      credential.update!(
        session_data: session_blob,
        last_login_at: Time.current,
        status: 'active'
      )
      logger.info "[Sysco] Session saved (cookies: #{cookies.size}, localStorage: #{local_storage.size}, sessionStorage: #{session_storage.size})"
    end

    def restore_session
      return false unless credential.session_data.present?
      return false unless credential.session_valid?

      begin
        data = JSON.parse(credential.session_data)

        cookies = data['cookies'] || data
        local_storage = data['local_storage'] || {}
        session_storage = data['session_storage'] || {}

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
          rescue StandardError
            nil
          end
        end

        # Navigate to the site so we have a JS context for storage injection
        begin
          browser.goto(BASE_URL)
        rescue Ferrum::PendingConnectionsError
          # Expected for SPA sites
        end
        sleep 2
        apply_stealth

        # Restore localStorage
        if local_storage.any?
          browser.evaluate(<<~JS)
            (function() {
              var data = #{local_storage.to_json};
              Object.keys(data).forEach(function(key) {
                try { localStorage.setItem(key, data[key]); } catch(e) {}
              });
            })()
          JS
        end

        # Restore sessionStorage
        if session_storage.any?
          browser.evaluate(<<~JS)
            (function() {
              var data = #{session_storage.to_json};
              Object.keys(data).forEach(function(key) {
                try { sessionStorage.setItem(key, data[key]); } catch(e) {}
              });
            })()
          JS
        end

        logger.info "[Sysco] Session restored (cookies: #{cookies.size}, localStorage: #{local_storage.size}, sessionStorage: #{session_storage.size})"
        true
      rescue JSON::ParserError => e
        logger.warn "[Sysco] Failed to parse session data: #{e.message}"
        false
      end
    end

    # ----------------------------------------------------------------
    # Diagnostics
    # ----------------------------------------------------------------

    def log_page_state(context)
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
        browser.evaluate('document.body?.innerText?.substring(0, 500)')
      rescue StandardError
        'could not read'
      end
      logger.info "[Sysco] #{context} — URL: #{current_url}, Title: #{page_title}"
      logger.debug "[Sysco] #{context} — Body: #{body_snippet}"
    end

    def diagnose_login_failure
      log_page_state('Login failure diagnosis')

      buttons = begin
        browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('button, a, input[type="submit"], [role="button"]');
            var info = [];
            for (var i = 0; i < els.length && i < 20; i++) {
              info.push(els[i].tagName + ':' + (els[i].innerText || els[i].value || '').trim().substring(0, 40));
            }
            return info.join(' | ');
          })()
        JS
      rescue StandardError
        'could not read'
      end
      logger.error "[Sysco] Visible buttons: #{buttons}"

      inputs = begin
        browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('input');
            var info = [];
            for (var i = 0; i < els.length && i < 20; i++) {
              var el = els[i];
              info.push(el.type + '#' + el.id + '.' + el.name + ' visible=' + (el.offsetHeight > 0));
            }
            return info.join(' | ');
          })()
        JS
      rescue StandardError
        'could not read'
      end
      logger.error "[Sysco] Visible inputs: #{inputs}"
    end
  end
end
