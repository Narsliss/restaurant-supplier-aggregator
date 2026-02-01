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
      @browser = Ferrum::Browser.new(
        headless: true,
        timeout: 30,
        window_size: [1920, 1080],
        browser_options: {
          "no-sandbox": true,
          "disable-gpu": true,
          "disable-dev-shm-usage": true
        }
      )
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

    def add_to_cart(items)
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
          browser.execute("arguments[0].value = arguments[1]", element, value)
          browser.execute("arguments[0].dispatchEvent(new Event('input', { bubbles: true }))", element)
          browser.execute("arguments[0].dispatchEvent(new Event('change', { bubbles: true }))", element)
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
        browser.execute("arguments[0].click()", element)
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
          # Check if element is visible via JS
          visible = browser.evaluate("(function(el) {
            if (!el) return false;
            var style = window.getComputedStyle(el);
            return style.display !== 'none' &&
                   style.visibility !== 'hidden' &&
                   style.opacity !== '0' &&
                   el.offsetWidth > 0 &&
                   el.offsetHeight > 0;
          })(arguments[0])", el) rescue false

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
          browser.cookies.set(
            name: cookie["name"],
            value: cookie["value"],
            domain: cookie["domain"],
            path: cookie["path"] || "/",
            expires: cookie["expires"],
            secure: cookie["secure"],
            httponly: cookie["httponly"]
          )
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
        error_msg = extract_text(".error-message, .alert-danger, .error") || "Login failed"
        credential.mark_failed!(error_msg)
        logger.error "[Scraper] Login failed for #{credential.supplier.name}: #{error_msg}"
        raise AuthenticationError, error_msg
      end
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
