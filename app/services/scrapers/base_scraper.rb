module Scrapers
  class BaseScraper
    # Error classes
    class AuthenticationError < StandardError; end
    class ScrapingError < StandardError; end
    class SessionExpiredError < StandardError; end
    
    class OrderMinimumError < StandardError
      attr_reader :minimum, :current_total
      def initialize(message, minimum:, current_total:)
        @minimum = minimum
        @current_total = current_total
        super(message)
      end
    end
    
    class ItemUnavailableError < StandardError
      attr_reader :items
      def initialize(message, items:)
        @items = items
        super(message)
      end
    end
    
    class PriceChangedError < StandardError
      attr_reader :changes
      def initialize(message, changes:)
        @changes = changes
        super(message)
      end
    end
    
    class CaptchaDetectedError < StandardError; end
    class AccountHoldError < StandardError; end
    class DeliveryUnavailableError < StandardError; end
    class RateLimitedError < StandardError; end
    class MaintenanceError < StandardError; end

    attr_reader :credential, :browser, :logger

    def initialize(credential)
      @credential = credential
      @logger = Rails.logger
    end

    def with_browser(&block)
      headless_mode = ENV.fetch("BROWSER_HEADLESS", "true") == "true"

      browser_opts = {
        headless: headless_mode,
        timeout: 30,
        process_timeout: 30,  # Allow 30 seconds for browser process to start
        window_size: [1920, 1080]
      }

      # Only use restrictive options in headless mode (for Docker/server environments)
      if headless_mode
        browser_opts[:browser_options] = {
          "no-sandbox": true,
          "disable-gpu": true,
          "disable-dev-shm-usage": true
        }
      else
        # For visible browser mode, use minimal options to allow window to display
        browser_opts[:browser_options] = {
          "no-sandbox": true,
          "start-maximized": true
        }
        # Explicitly set headless to "new" false mode
        browser_opts[:headless] = false
      end

      # Allow custom Chrome/Chromium path via environment variable
      if ENV["BROWSER_PATH"].present?
        browser_opts[:browser_path] = ENV["BROWSER_PATH"]
      end

      logger.info "[Scraper] Starting browser (headless=#{headless_mode})"
      @browser = Ferrum::Browser.new(**browser_opts)
      yield(browser)
    ensure
      browser&.quit
    end

    def login
      raise NotImplementedError, "Subclass must implement #login"
    end

    def login_with_2fa_support
      with_browser do
        # Try to use trusted device token first
        if restore_trusted_device
          navigate_to(supplier_base_url)
          return true if logged_in?
        end

        # Try to restore existing session
        if restore_session
          navigate_to(supplier_base_url)
          return true if logged_in?
        end

        # Perform fresh login
        perform_login_steps

        # Check if 2FA is required
        two_fa_handler = Authentication::TwoFactorHandler.new(
          credential, browser, operation_type: "login"
        )

        if two_fa_handler.two_fa_required?
          two_fa_handler.initiate_2fa_flow
        end

        finalize_login
      end
    end

    def scrape_prices(product_skus)
      raise NotImplementedError, "Subclass must implement #scrape_prices"
    end

    # Scrape the supplier's catalog by searching for terms.
    # Returns an array of hashes: { supplier_sku, supplier_name, current_price, pack_size, in_stock, category }
    # Default implementation searches the supplier site for each term.
    def scrape_catalog(search_terms, max_per_term: 20)
      results = []

      with_browser do
        # Use perform_login_steps (not login) to avoid nested with_browser blocks.
        # First try restoring session, fall back to a fresh login within this browser.
        unless restore_session && (navigate_to(supplier_base_url) || true) && logged_in?
          perform_login_steps
          sleep 2
          unless logged_in?
            raise AuthenticationError, "Could not log in for catalog import"
          end
          save_session
        end

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

    # Override in subclasses to implement supplier-specific catalog search
    def search_supplier_catalog(term, max: 20)
      raise NotImplementedError, "Subclass must implement #search_supplier_catalog"
    end

    def add_to_cart(items, delivery_date: nil)
      raise NotImplementedError, "Subclass must implement #add_to_cart"
    end

    def checkout
      raise NotImplementedError, "Subclass must implement #checkout"
    end

    def logged_in?
      raise NotImplementedError, "Subclass must implement #logged_in?"
    end

    protected

    def supplier_base_url
      credential.supplier.base_url
    end

    def supplier_login_url
      credential.supplier.login_url
    end

    def navigate_to(url)
      logger.debug "[Scraper] Navigating to: #{url}"
      browser.goto(url)
      wait_for_page_load
    end

    def fill_field(selector, value)
      element = find_first_visible(selector)
      return unless element

      begin
        element.focus
        element.type(value, :clear)
      rescue Ferrum::CoordinatesNotFoundError, Ferrum::NodeNotFoundError, Ferrum::BrowserError => e
        # Element found in DOM but not interactable — try clicking first to focus
        logger.debug "[Scraper] focus failed for '#{selector}', trying click: #{e.message}"
        begin
          element.click
          element.type(value, :clear)
        rescue => retry_error
          # Last resort: use JavaScript to set value directly
          logger.debug "[Scraper] click+type failed, using JS: #{retry_error.message}"
          element.evaluate("this.value = ''")
          element.evaluate("this.value = '#{value.gsub("'", "\\\\'")}'")
          element.evaluate("this.dispatchEvent(new Event('input', { bubbles: true }))")
          element.evaluate("this.dispatchEvent(new Event('change', { bubbles: true }))")
        end
      end
    end

    def click(selector)
      element = find_first_visible(selector)
      return unless element

      begin
        element.click
      rescue Ferrum::CoordinatesNotFoundError, Ferrum::NodeNotFoundError, Ferrum::BrowserError => e
        logger.debug "[Scraper] click failed for '#{selector}', using JS: #{e.message}"
        element.evaluate("this.click()")
      end
    end

    def wait_for_page_load
      sleep 0.5
    end

    def wait_for_selector(selector, timeout: 10)
      start_time = Time.current
      loop do
        return browser.at_css(selector) if browser.at_css(selector)
        if Time.current - start_time > timeout
          raise ScrapingError, "Timeout waiting for #{selector}"
        end
        sleep 0.1
      end
    end

    def wait_for_any_selector(*selectors, timeout: 10)
      start_time = Time.current
      loop do
        selectors.each do |selector|
          element = browser.at_css(selector)
          return element if element
        end
        if Time.current - start_time > timeout
          raise ScrapingError, "Timeout waiting for any of: #{selectors.join(', ')}"
        end
        sleep 0.1
      end
    end

    def find_first_visible(selector)
      # Try each selector individually to find a visible, interactable element
      selectors = selector.split(",").map(&:strip)

      selectors.each do |sel|
        elements = browser.css(sel)
        elements.each do |el|
          visible = el.evaluate(<<~JS) rescue false
            var s = window.getComputedStyle(this);
            s.display !== 'none' &&
            s.visibility !== 'hidden' &&
            s.opacity !== '0' &&
            this.offsetWidth > 0 &&
            this.offsetHeight > 0
          JS

          return el if visible
        end
      end

      # Fallback: return first match regardless of visibility
      browser.at_css(selector)
    end

    def extract_text(selector)
      browser.at_css(selector)&.text&.strip
    end

    def extract_price(text)
      return nil unless text
      # Extract numeric price from text like "$25.99" or "25.99"
      match = text.match(/[\d,]+\.?\d*/)
      return nil unless match
      match[0].gsub(",", "").to_f
    end

    def save_session
      cookies = browser.cookies.all.transform_values(&:to_h)
      credential.update!(
        session_data: cookies.to_json,
        last_login_at: Time.current,
        status: "active"
      )
      logger.info "[Scraper] Session saved for #{credential.supplier.name}"
    end

    def restore_session
      return false unless credential.session_data.present?
      return false unless credential.session_valid?

      begin
        cookies = JSON.parse(credential.session_data)
        cookies.each do |_name, cookie|
          next unless cookie.is_a?(Hash) && cookie["name"].present? && cookie["value"].present?

          params = {
            name: cookie["name"].to_s,
            value: cookie["value"].to_s,
            domain: cookie["domain"].to_s,
            path: cookie["path"].present? ? cookie["path"].to_s : "/"
          }
          # Only include optional params if they have valid values
          params[:secure] = !!cookie["secure"] unless cookie["secure"].nil?
          params[:httponly] = !!cookie["httponly"] unless cookie["httponly"].nil?
          if cookie["expires"].is_a?(Numeric) && cookie["expires"] > 0
            params[:expires] = cookie["expires"].to_i
          end

          begin
            browser.cookies.set(**params)
          rescue Ferrum::BrowserError => e
            logger.debug "[Scraper] Skipping cookie '#{params[:name]}': #{e.message}"
          end
        end
        logger.info "[Scraper] Session restored for #{credential.supplier.name}"
        true
      rescue JSON::ParserError => e
        logger.warn "[Scraper] Failed to parse session data: #{e.message}"
        false
      end
    end

    def restore_trusted_device
      return false unless credential.trusted_device_valid?
      # Override in subclasses to implement trusted device restoration
      false
    end

    def perform_login_steps
      raise NotImplementedError, "Subclass must implement #perform_login_steps"
    end

    def finalize_login
      if logged_in?
        save_session
        credential.mark_active!
        logger.info "[Scraper] Login successful for #{credential.supplier.name}"
        true
      else
        full_error = diagnose_login_failure
        credential.mark_failed!(full_error)
        logger.error "[Scraper] Login failed for #{credential.supplier.name}: #{full_error}"
        raise AuthenticationError, full_error
      end
    end

    def diagnose_login_failure
      supplier_name = credential.supplier.name
      current_url = browser.current_url rescue "unknown"
      page_title = browser.evaluate("document.title") rescue "unknown"

      # Try many error selectors
      error_selectors = [
        ".error-message", ".login-error", ".alert-danger", ".alert-error",
        ".error", ".form-error", ".validation-error", ".invalid-feedback",
        "[role='alert']", ".notification-error", ".toast-error",
        ".field-error", ".input-error", ".message-error", ".flash-error",
        ".snackbar-error", ".toast-message", ".notice-error",
        "p.error", "span.error", "div.error",
        "[data-testid*='error']", "[data-testid*='alert']",
        ".MuiAlert-root", ".ant-alert-error", ".chakra-alert"
      ]

      site_error = nil
      matched_selector = nil
      error_selectors.each do |sel|
        text = extract_text(sel)
        if text.present?
          site_error = text
          matched_selector = sel
          break
        end
      end

      # Also scan for error-like text via JavaScript (some SPAs use custom elements)
      if site_error.nil?
        js_error = browser.evaluate(<<~JS) rescue nil
          (function() {
            // Look for elements with error-related attributes
            var errorEls = document.querySelectorAll('[class*="error" i], [class*="alert" i], [class*="invalid" i], [class*="fail" i]');
            for (var i = 0; i < errorEls.length; i++) {
              var text = errorEls[i].innerText?.trim();
              if (text && text.length > 3 && text.length < 500) return text;
            }
            // Check for aria-live regions (used for dynamic error messages)
            var liveEls = document.querySelectorAll('[aria-live="polite"], [aria-live="assertive"]');
            for (var i = 0; i < liveEls.length; i++) {
              var text = liveEls[i].innerText?.trim();
              if (text && text.length > 3 && text.length < 500) return text;
            }
            return null;
          })()
        JS
        if js_error.present?
          site_error = js_error
          matched_selector = "JS scan (class*=error/alert/invalid)"
        end
      end

      # Build diagnostic details
      details = []
      details << "URL after login: #{current_url}"
      details << "Page title: '#{page_title}'"

      if site_error.present?
        details << "Site error (#{matched_selector}): #{site_error}"
        logger.info "[Scraper] Error found via '#{matched_selector}': #{site_error}"
      else
        body_text = browser.evaluate("document.body?.innerText?.substring(0, 500)") rescue ""
        snippet = body_text.to_s.strip.truncate(300)
        details << "No error message found on page"
        details << "Page content: #{snippet}" if snippet.present?

        # List all visible inputs for debugging
        inputs_dump = browser.evaluate(<<~JS) rescue ""
          (function() {
            var inputs = document.querySelectorAll('input, button, [role="button"]');
            var info = [];
            for (var i = 0; i < inputs.length && i < 15; i++) {
              var el = inputs[i];
              var s = window.getComputedStyle(el);
              if (s.display === 'none') continue;
              info.push(el.tagName + '[type=' + (el.type||'') + ',name=' + (el.name||'') + ',id=' + (el.id||'') + ']');
            }
            return info.join(', ');
          })()
        JS
        details << "Visible inputs: #{inputs_dump}" if inputs_dump.present?
      end

      error_summary = site_error.present? ? site_error : "Login failed — #{supplier_name} did not show an error message"
      "#{error_summary} (#{details.join('; ')})"
    end

    def detect_error_conditions
      detect_captcha
      detect_maintenance
      detect_account_issues
    end

    def detect_captcha
      captcha_indicators = [
        "#captcha",
        ".captcha-container",
        "iframe[src*='recaptcha']",
        ".g-recaptcha",
        "#challenge-form",
        "[data-testid='captcha']"
      ]

      captcha_indicators.each do |selector|
        if browser.at_css(selector)
          logger.warn "[Scraper] CAPTCHA detected"
          raise CaptchaDetectedError, "CAPTCHA detected. Manual intervention required."
        end
      end
    end

    def detect_maintenance
      page_text = browser.body&.text&.downcase || ""
      maintenance_indicators = [
        "maintenance",
        "temporarily unavailable",
        "scheduled downtime",
        "under construction",
        "be right back"
      ]

      maintenance_indicators.each do |indicator|
        if page_text.include?(indicator)
          logger.warn "[Scraper] Site maintenance detected"
          raise MaintenanceError, "Supplier site is under maintenance. Please try again later."
        end
      end
    end

    def detect_account_issues
      # Override in subclasses for supplier-specific detection
    end

    def rate_limit_delay
      sleep rand(1.0..2.5)
    end
  end
end
