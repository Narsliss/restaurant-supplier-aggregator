module Scrapers
  class ChefsWarehouseScraper < BaseScraper
    BASE_URL = "https://www.chefswarehouse.com".freeze
    LOGIN_URL = "#{BASE_URL}/login".freeze
    ORDER_MINIMUM = 200.00

    def login
      with_browser do
        navigate_to(BASE_URL)
        
        if restore_session
          browser.refresh
          return true if logged_in?
        end

        navigate_to(LOGIN_URL)
        wait_for_selector("#email, input[name='email'], input[type='email']")

        fill_field("#email, input[name='email'], input[type='email']", credential.username)
        fill_field("#password, input[name='password']", credential.password)
        click("button[type='submit'], .login-btn, .sign-in-button")

        wait_for_page_load
        sleep 2

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          error_msg = extract_text(".error-message, .login-error, .alert-danger") || "Login failed"
          credential.mark_failed!(error_msg)
          raise AuthenticationError, error_msg
        end
      end
    end

    def logged_in?
      browser.at_css(".account-menu, .user-nav, .my-account-link, [data-testid='account']").present?
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

    def add_to_cart(items)
      with_browser do
        login unless logged_in?

        items.each do |item|
          # Search for product by SKU
          navigate_to("#{BASE_URL}/search?q=#{item[:sku]}")
          wait_for_selector(".product-list, .search-results", timeout: 10)

          # Click on the product
          product_link = browser.at_css("a[href*='#{item[:sku]}'], .product-item a")
          if product_link
            product_link.click
            wait_for_selector(".product-detail, .pdp-container")
          end

          # Set quantity
          qty_field = browser.at_css("input[name='quantity'], .qty-input")
          if qty_field
            qty_field.focus
            qty_field.type(item[:quantity].to_s, :clear)
          end

          click(".add-to-cart, .add-to-order-btn")
          
          begin
            wait_for_selector(".cart-notification, .added-message", timeout: 5)
          rescue ScrapingError
            logger.warn "[ChefsWarehouse] No cart confirmation for SKU #{item[:sku]}"
          end

          rate_limit_delay
        end

        true
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

    protected

    def perform_login_steps
      navigate_to(LOGIN_URL)
      wait_for_selector("#email, input[name='email']")

      fill_field("#email, input[name='email']", credential.username)
      fill_field("#password, input[name='password']", credential.password)
      click("button[type='submit'], .login-btn")

      wait_for_page_load
      sleep 2
    end

    private

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
