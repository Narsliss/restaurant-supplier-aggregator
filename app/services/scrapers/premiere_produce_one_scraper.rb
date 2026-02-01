module Scrapers
  class PremiereProduceOneScraper < BaseScraper
    BASE_URL = "https://www.premiereproduceone.com".freeze
    LOGIN_URL = "#{BASE_URL}/customer-login/".freeze
    ORDER_MINIMUM = 0.00

    def login
      with_browser do
        navigate_to(BASE_URL)

        if restore_session
          browser.refresh
          return true if logged_in?
        end

        navigate_to(LOGIN_URL)
        wait_for_selector("input[name='email'], #email, input[type='email'], input[name='username'], #username")

        fill_field("input[name='email'], #email, input[type='email'], input[name='username'], #username", credential.username)
        fill_field("input[name='password'], #password, input[type='password']", credential.password)
        click("button[type='submit'], .login-button, .btn-login, input[type='submit']")

        wait_for_page_load
        sleep 2

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          error_msg = extract_text(".error, .alert-error, .login-error, .error-message, .alert-danger") || "Login failed"
          credential.mark_failed!(error_msg)
          raise AuthenticationError, error_msg
        end
      end
    end

    def logged_in?
      browser.at_css(".user-menu, .account-dropdown, .logged-in, [data-user-logged-in], .my-account, .account-nav").present?
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

    def perform_login_steps
      navigate_to(LOGIN_URL)
      wait_for_selector("input[name='email'], #email, input[name='username'], #username")

      fill_field("input[name='email'], #email, input[name='username'], #username", credential.username)
      fill_field("input[name='password'], #password", credential.password)
      click("button[type='submit'], .login-button, input[type='submit']")

      wait_for_page_load
      sleep 2
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

        products << {
          supplier_sku: sku,
          supplier_name: name.truncate(255),
          current_price: price,
          pack_size: pack_size,
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
  end
end
