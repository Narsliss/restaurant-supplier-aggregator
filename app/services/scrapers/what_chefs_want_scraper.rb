module Scrapers
  class WhatChefsWantScraper < BaseScraper
    BASE_URL = "https://www.whatchefswant.com".freeze
    LOGIN_URL = "#{BASE_URL}/customer-login/".freeze
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

    def add_to_cart(items, delivery_date: nil)
      @target_delivery_date = delivery_date

      with_browser do
        unless restore_session && logged_in?
          perform_login_steps
          save_session
        end

        added_items = []
        failed_items = []

        items.each do |item|
          begin
            add_single_item_to_cart(item)
            added_items << item
            logger.info "[WhatChefsWant] Added SKU #{item[:sku]} (qty: #{item[:quantity]})"
          rescue => e
            logger.warn "[WhatChefsWant] Failed to add SKU #{item[:sku]}: #{e.message}"
            failed_items << { sku: item[:sku], error: e.message, name: item[:name] }
          end

          rate_limit_delay
        end

        if failed_items.any?
          raise ItemUnavailableError.new(
            "#{failed_items.count} item(s) could not be added",
            items: failed_items
          )
        end

        { added: added_items.count }
      end
    end

    private

    def add_single_item_to_cart(item)
      # Try direct product page first
      navigate_to("#{BASE_URL}/products/#{item[:sku]}")
      sleep 2

      # Check if product page loaded
      product_found = false
      begin
        wait_for_any_selector(
          ".product-page",
          ".product-detail",
          ".product-info",
          ".pdp-container",
          timeout: 5
        )
        product_found = true
      rescue ScrapingError
        # Product page not found, try search
        logger.debug "[WhatChefsWant] Direct product page not found, trying search"
      end

      unless product_found
        # Try searching for the product
        encoded_sku = CGI.escape(item[:sku].to_s)
        navigate_to("#{BASE_URL}/search?q=#{encoded_sku}")
        sleep 2

        # Click on first matching product
        product_link = browser.at_css(".product-card a, .product-item a, .search-result a")
        if product_link
          product_link.click
          sleep 2
          wait_for_any_selector(".product-page", ".product-detail", timeout: 10)
        else
          raise ScrapingError, "Product not found for SKU #{item[:sku]}"
        end
      end

      # Set quantity
      qty_selectors = [
        "input[name='quantity']",
        ".quantity-field",
        "#quantity",
        "input[type='number']",
        ".qty-input"
      ]

      qty_field = nil
      qty_selectors.each do |sel|
        qty_field = browser.at_css(sel)
        break if qty_field
      end

      if qty_field && item[:quantity].to_i > 1
        qty_field.focus
        qty_field.type(item[:quantity].to_s, :clear)
        sleep 0.5
      end

      # Click add to cart
      add_btn_selectors = [
        ".add-to-cart",
        ".btn-add-cart",
        "[data-action='add-to-cart']",
        "button.add-to-cart",
        "#add-to-cart",
        ".product-add-to-cart"
      ]

      add_btn = nil
      add_btn_selectors.each do |sel|
        add_btn = browser.at_css(sel)
        break if add_btn
      end

      if add_btn
        click_element(add_btn)
      else
        raise ScrapingError, "Add to cart button not found for SKU #{item[:sku]}"
      end

      # Wait for confirmation
      wait_for_cart_confirmation
    end

    def click_element(element)
      begin
        element.click
      rescue => e
        logger.debug "[WhatChefsWant] Native click failed: #{e.message}, trying JS click"
        element.evaluate("this.click()")
      end
    end

    def wait_for_cart_confirmation
      begin
        wait_for_any_selector(
          ".cart-added",
          ".success-message",
          ".cart-updated",
          ".cart-notification",
          ".added-to-cart",
          timeout: 5
        )
        sleep 1
      rescue ScrapingError
        logger.debug "[WhatChefsWant] No confirmation modal, checking cart state"
        sleep 1
      end
    end

    def wait_for_any_selector(*selectors, timeout: 10)
      options = selectors.last.is_a?(Hash) ? selectors.pop : {}
      timeout_val = options[:timeout] || timeout

      start_time = Time.current
      while Time.current - start_time < timeout_val
        selectors.each do |sel|
          return true if browser.at_css(sel)
        end
        sleep 0.3
      end

      raise ScrapingError, "None of selectors found: #{selectors.join(', ')}"
    end

    public

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
        logger.debug "[WhatChefsWant] Failed to extract catalog item: #{e.message}"
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
