module Scrapers
  class UsFoodsScraper < BaseScraper
    BASE_URL = "https://www.usfoods.com".freeze
    LOGIN_URL = "#{BASE_URL}/sign-in".freeze
    ORDER_MINIMUM = 250.00

    def login
      with_browser do
        navigate_to(BASE_URL)
        
        if restore_session
          browser.refresh
          return true if logged_in?
        end

        navigate_to(LOGIN_URL)
        wait_for_selector("#username, #email, input[name='username']")

        fill_field("#username, #email, input[name='username']", credential.username)
        fill_field("#password, input[name='password']", credential.password)
        click("button[type='submit'], input[type='submit'], .login-button")

        wait_for_page_load
        sleep 2 # Wait for any redirects

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          error_msg = extract_text(".error-message, .alert-danger") || "Login failed"
          credential.mark_failed!(error_msg)
          raise AuthenticationError, error_msg
        end
      end
    end

    def logged_in?
      browser.at_css(".user-account-menu, .logged-in-indicator, .account-nav, [data-testid='user-menu']").present?
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
            logger.warn "[UsFoods] Failed to scrape SKU #{sku}: #{e.message}"
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
          navigate_to("#{BASE_URL}/product/#{item[:sku]}")
          wait_for_selector(".add-to-cart, .add-to-order, [data-testid='add-to-cart']")

          # Set quantity
          qty_field = browser.at_css("input[name='quantity'], .quantity-input, [data-testid='quantity']")
          if qty_field
            qty_field.focus
            qty_field.type(item[:quantity].to_s, :clear)
          end

          click(".add-to-cart, .add-to-order, [data-testid='add-to-cart']")
          
          # Wait for cart confirmation
          begin
            wait_for_selector(".cart-confirmation, .added-to-cart, .cart-updated", timeout: 5)
          rescue ScrapingError
            logger.warn "[UsFoods] No cart confirmation for SKU #{item[:sku]}"
          end

          rate_limit_delay
        end

        true
      end
    end

    def checkout
      with_browser do
        navigate_to("#{BASE_URL}/cart")
        wait_for_selector(".cart-contents, .cart-items, [data-testid='cart']")

        # Pre-checkout validations
        validate_cart_before_checkout

        # Check order minimum
        minimum_check = check_order_minimum_at_checkout
        unless minimum_check[:met]
          raise OrderMinimumError.new(
            "Order minimum not met",
            minimum: minimum_check[:minimum],
            current_total: minimum_check[:current]
          )
        end

        # Check for unavailable items
        unavailable = detect_unavailable_items_in_cart
        if unavailable.any?
          raise ItemUnavailableError.new(
            "#{unavailable.count} item(s) are unavailable",
            items: unavailable
          )
        end

        # Check for price changes
        price_changes = detect_price_changes_in_cart
        if price_changes.any?
          raise PriceChangedError.new(
            "Prices have changed for #{price_changes.count} item(s)",
            changes: price_changes
          )
        end

        # Proceed to checkout
        click(".checkout-button, .proceed-to-checkout, [data-testid='checkout']")
        wait_for_selector(".order-review, .checkout-summary, [data-testid='order-review']")

        # Verify delivery date is available
        unless delivery_date_available?
          raise DeliveryUnavailableError, "No delivery dates available for your location"
        end

        # Place order
        click(".place-order-button, .submit-order, [data-testid='place-order']")
        wait_for_confirmation_or_error

        {
          confirmation_number: extract_text(".confirmation-number, .order-number, [data-testid='confirmation']"),
          total: extract_price(extract_text(".order-total, .total-amount")),
          delivery_date: extract_text(".delivery-date, .estimated-delivery")
        }
      end
    end

    protected

    def perform_login_steps
      navigate_to(LOGIN_URL)
      wait_for_selector("#username, #email, input[name='username']")

      fill_field("#username, #email, input[name='username']", credential.username)
      fill_field("#password, input[name='password']", credential.password)
      click("button[type='submit'], input[type='submit'], .login-button")

      wait_for_page_load
      sleep 2
    end

    private

    def search_supplier_catalog(term, max: 20)
      encoded = CGI.escape(term)
      navigate_to("#{BASE_URL}/search?q=#{encoded}")
      sleep 2

      products = []
      items = browser.css(".product-card, .product-item, .product-tile, [data-testid*='product'], .search-result-item")

      items.first(max).each do |item|
        name = item.at_css(".product-title, .product-name, h3, h4")&.text&.strip
        next if name.blank?

        price_text = item.at_css(".product-price, .price, [data-testid='price']")&.text
        price = extract_price(price_text) if price_text

        href = item.at_css("a[href*='/product/']")&.attribute("href").to_s
        sku = item.attribute("data-sku").to_s.presence
        sku ||= item.at_css("[data-sku]")&.attribute("data-sku").to_s.presence
        sku ||= href.scan(%r{/product/([^/?#]+)}).flatten.first
        sku ||= name.parameterize
        next if sku.blank?

        pack_size = item.at_css(".pack-size, .unit-size, .product-pack")&.text&.strip

        products << {
          supplier_sku: sku,
          supplier_name: name.truncate(255),
          current_price: price,
          pack_size: pack_size,
          in_stock: item.at_css(".out-of-stock, .unavailable").nil?,
          category: nil,
          scraped_at: Time.current
        }
      rescue => e
        logger.debug "[UsFoods] Failed to extract catalog item: #{e.message}"
      end

      products
    end

    def scrape_product(sku)
      navigate_to("#{BASE_URL}/product/#{sku}")

      return nil unless browser.at_css(".product-detail, .product-info, [data-testid='product']")

      {
        supplier_sku: sku,
        supplier_name: extract_text(".product-title, .product-name, h1"),
        current_price: extract_price(extract_text(".product-price, .price, [data-testid='price']")),
        pack_size: extract_text(".pack-size, .unit-size, .product-pack"),
        in_stock: browser.at_css(".out-of-stock, .unavailable").nil?,
        scraped_at: Time.current
      }
    end

    def check_order_minimum_at_checkout
      subtotal_text = extract_text(".cart-subtotal, .subtotal, [data-testid='subtotal']")
      current_total = extract_price(subtotal_text) || 0

      minimum_text = extract_text(".order-minimum-message, .minimum-order")
      minimum = if minimum_text
        extract_price(minimum_text) || ORDER_MINIMUM
      else
        ORDER_MINIMUM
      end

      {
        met: current_total >= minimum,
        minimum: minimum,
        current: current_total
      }
    end

    def detect_unavailable_items_in_cart
      unavailable = []

      browser.css(".cart-item, .line-item, [data-testid='cart-item']").each do |item|
        if item.at_css(".out-of-stock, .unavailable, .item-unavailable")
          unavailable << {
            sku: item.at_css("[data-sku]")&.attribute("data-sku"),
            name: item.at_css(".item-name, .product-name")&.text&.strip,
            message: item.at_css(".availability-message")&.text&.strip
          }
        end
      end

      unavailable
    end

    def detect_price_changes_in_cart
      changes = []

      browser.css(".cart-item, .line-item").each do |item|
        price_warning = item.at_css(".price-changed-warning, .price-alert")
        next unless price_warning

        changes << {
          sku: item.at_css("[data-sku]")&.attribute("data-sku"),
          name: item.at_css(".item-name, .product-name")&.text&.strip,
          old_price: extract_price(item.at_css(".original-price, .was-price")&.text),
          new_price: extract_price(item.at_css(".current-price, .now-price")&.text)
        }
      end

      changes
    end

    def validate_cart_before_checkout
      detect_error_conditions

      if browser.at_css(".empty-cart, .cart-empty")
        raise ScrapingError, "Cart is empty"
      end
    end

    def delivery_date_available?
      browser.at_css(".delivery-date-selector option:not([disabled]), .delivery-slot:not(.unavailable)").present?
    end

    def wait_for_confirmation_or_error
      start_time = Time.current
      timeout = 30

      loop do
        return true if browser.at_css(".order-confirmation, .confirmation-page, [data-testid='confirmation']")

        error_msg = browser.at_css(".checkout-error, .order-error, .alert-danger")&.text&.strip
        handle_checkout_error(error_msg) if error_msg

        raise ScrapingError, "Checkout timeout" if Time.current - start_time > timeout
        sleep 0.5
      end
    end

    def handle_checkout_error(error_msg)
      case error_msg.downcase
      when /minimum.*order/
        raise OrderMinimumError.new(error_msg, minimum: ORDER_MINIMUM, current_total: 0)
      when /credit.*hold/, /account.*hold/
        raise AccountHoldError, error_msg
      when /out of stock/, /unavailable/
        raise ItemUnavailableError.new(error_msg, items: [])
      when /delivery.*unavailable/
        raise DeliveryUnavailableError, error_msg
      else
        raise ScrapingError, "Checkout failed: #{error_msg}"
      end
    end

    def detect_account_issues
      hold_banner = browser.at_css(".account-hold-banner, .account-alert")
      if hold_banner
        raise AccountHoldError, hold_banner.text.strip
      end

      credit_warning = browser.at_css(".credit-limit-warning, .credit-alert")
      if credit_warning
        raise AccountHoldError, "Credit limit reached: #{credit_warning.text.strip}"
      end
    end
  end
end
