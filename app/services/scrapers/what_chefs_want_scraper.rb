module Scrapers
  class WhatChefsWantScraper < BaseScraper
    BASE_URL = "https://www.whatchefswant.com".freeze
    LOGIN_URL = "#{BASE_URL}/login".freeze
    ORDER_MINIMUM = 150.00

    def login
      with_browser do
        navigate_to(BASE_URL)
        
        if restore_session
          browser.refresh
          return true if logged_in?
        end

        navigate_to(LOGIN_URL)
        wait_for_selector("input[name='email'], #email, input[type='email']")

        fill_field("input[name='email'], #email", credential.username)
        fill_field("input[name='password'], #password", credential.password)
        click("button[type='submit'], .login-button, .btn-login")

        wait_for_page_load
        sleep 2

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          error_msg = extract_text(".error, .alert-error, .login-error") || "Login failed"
          credential.mark_failed!(error_msg)
          raise AuthenticationError, error_msg
        end
      end
    end

    def logged_in?
      browser.at_css(".user-menu, .account-dropdown, .logged-in, [data-user-logged-in]").present?
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
            logger.warn "[WhatChefsWant] Failed to scrape SKU #{sku}: #{e.message}"
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
            logger.warn "[WhatChefsWant] Product page not found for SKU #{item[:sku]}"
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
            logger.warn "[WhatChefsWant] No cart confirmation for SKU #{item[:sku]}"
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

        click(".checkout, .btn-checkout, [data-action='checkout']")
        wait_for_selector(".checkout-page, .order-review")

        # Select delivery date if required
        select_delivery_date_if_needed

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

    def perform_login_steps
      navigate_to(LOGIN_URL)
      wait_for_selector("input[name='email'], #email")

      fill_field("input[name='email'], #email", credential.username)
      fill_field("input[name='password'], #password", credential.password)
      click("button[type='submit'], .login-button")

      wait_for_page_load
      sleep 2
    end

    private

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

    def check_order_minimum_at_checkout
      subtotal_text = extract_text(".subtotal, .cart-total")
      current_total = extract_price(subtotal_text) || 0

      minimum_msg = extract_text(".minimum-order-message, .order-minimum")
      minimum = if minimum_msg
        extract_price(minimum_msg) || ORDER_MINIMUM
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

    def select_delivery_date_if_needed
      date_selector = browser.at_css(".delivery-date-select, select[name='delivery_date']")
      return unless date_selector

      # Select first available date
      first_option = browser.at_css(".delivery-date-select option:not([disabled]):not([value='']), select[name='delivery_date'] option:not([disabled]):not([value=''])")
      if first_option
        date_selector.select(first_option.text)
      else
        raise DeliveryUnavailableError, "No delivery dates available"
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
  end
end
