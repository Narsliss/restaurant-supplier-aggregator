module Scrapers
  class WhatChefsWantScraper < BaseScraper
    BASE_URL = "https://www.whatchefswant.com".freeze
    PLATFORM_URL = "https://whatchefswant.cutanddry.com".freeze
    LOGIN_URL = "#{BASE_URL}/customer-login/".freeze
    ORDER_MINIMUM = 150.00

    def login
      with_browser do
        navigate_to(BASE_URL)

        if restore_session
          browser.refresh
          return true if logged_in?
        end

        # What Chefs Want uses a welcome URL for authentication —
        # the user pastes a long encoded link from their supplier email
        # that logs them in directly without username/password.
        welcome_url = credential.username
        if welcome_url.present? && welcome_url.start_with?("http")
          login_via_welcome_url(welcome_url)
        else
          login_via_credentials
        end
      end
    end

    private

    def login_via_welcome_url(url)
      logger.info "[WhatChefsWant] Logging in via welcome URL: #{url.truncate(80)}"
      navigate_to(url)
      wait_for_page_load

      # The welcome URL (email.cutanddry.com/c/...) redirects to
      # whatchefswant.cutanddry.com (a React SPA white-label platform).
      # We need to wait for: 1) redirects to complete, 2) React to hydrate/render.
      # The page body initially shows just "Home" until React mounts.
      logger.info "[WhatChefsWant] Waiting for SPA to load..."
      wait_for_spa_load

      # Check login state after SPA has loaded
      5.times do |i|
        current_url = browser.current_url rescue "unknown"
        page_title = browser.evaluate("document.title") rescue "unknown"
        body_length = browser.evaluate("document.body ? document.body.innerText.length : 0") rescue 0
        link_count = browser.evaluate("document.querySelectorAll('a').length") rescue 0
        logger.info "[WhatChefsWant] Check #{i + 1}: URL=#{current_url}, Title=#{page_title}, body_length=#{body_length}, links=#{link_count}"

        break if logged_in?

        # Wait for additional JS rendering
        sleep 3
      end

      if logged_in?
        save_session
        credential.mark_active!
        true
      else
        # Log the page content for debugging
        current_url = browser.current_url rescue "unknown"
        page_title = browser.evaluate("document.title") rescue "unknown"
        body_snippet = browser.evaluate("document.body ? document.body.innerText.substring(0, 500) : 'no body'") rescue "could not read"
        logger.error "[WhatChefsWant] Welcome URL login failed. URL: #{current_url}, Title: #{page_title}"
        logger.error "[WhatChefsWant] Page content: #{body_snippet}"

        error_msg = "Welcome URL did not log in. The link may have expired — check for a newer email from What Chefs Want."
        credential.mark_failed!(error_msg)
        raise AuthenticationError, error_msg
      end
    end

    def login_via_credentials
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

    public

    def logged_in?
      # The WCW platform lives on whatchefswant.cutanddry.com (React SPA).
      # After welcome URL login, the browser ends up there.

      # 1. Look for common logged-in UI elements
      has_user_element = browser.at_css(
        ".user-menu, .account-dropdown, .logged-in, [data-user-logged-in], " \
        ".my-account, .account-menu, .user-info, .user-name, .welcome-message, " \
        "a[href*='logout'], a[href*='sign-out'], a[href*='signout'], " \
        "a[href*='my-account'], a[href*='account'], " \
        ".cart, .shopping-cart, [data-cart], .header-cart, " \
        "nav a, .navbar a, header a[href*='order']"
      ).present?

      return true if has_user_element

      # 2. Check via JavaScript — look for React-rendered auth state or nav elements
      js_logged_in = browser.evaluate(<<~JS) rescue false
        (function() {
          // Check for any navigation links (React SPA renders these when logged in)
          var navLinks = document.querySelectorAll('nav a, header a, [class*="nav"] a');
          if (navLinks.length > 2) return true;

          // Check for user-related text content
          var body = document.body ? document.body.innerText : '';
          if (body.match(/my account|log ?out|sign ?out|order|cart/i)) return true;

          // Check for auth tokens in localStorage
          var keys = Object.keys(localStorage || {});
          for (var i = 0; i < keys.length; i++) {
            if (keys[i].match(/token|auth|session|user/i)) return true;
          }

          return false;
        })()
      JS

      return true if js_logged_in

      # 3. Check if we're on the platform (cutanddry.com) and NOT on a login page
      current_url = browser.current_url rescue ""
      on_platform = current_url.present? && (
        current_url.include?("whatchefswant.com") ||
        current_url.include?("whatchefswant.cutanddry.com")
      )
      not_on_login = on_platform &&
        !current_url.include?("login") &&
        !current_url.include?("sign-in") &&
        !current_url.include?("signin")

      if not_on_login
        has_login_form = browser.at_css(
          "input[type='password'], form[action*='login'], .login-form"
        ).present?
        return true unless has_login_form
      end

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
      navigate_to("#{PLATFORM_URL}/products/#{item[:sku]}")
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
        navigate_to("#{PLATFORM_URL}/search?q=#{encoded_sku}")
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
        navigate_to("#{PLATFORM_URL}/cart")
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
      welcome_url = credential.username
      if welcome_url.present? && welcome_url.start_with?("http")
        # Welcome URL auth — navigate and wait for SPA
        logger.info "[WhatChefsWant] perform_login_steps via welcome URL"
        navigate_to(welcome_url)
        wait_for_page_load
        wait_for_spa_load

        5.times do |i|
          break if logged_in?
          sleep 3
        end
      else
        # Password-based login
        navigate_to(LOGIN_URL)
        wait_for_selector("input[name='email'], #email")

        fill_field("input[name='email'], #email", credential.username)
        fill_field("input[name='password'], #password", credential.password)
        click("button[type='submit'], .login-button")

        wait_for_page_load
        sleep 2
      end
    end

    private

    # Wait for the Cut+Dry React SPA to fully hydrate.
    # The page initially renders as just "Home" until React mounts and renders the full UI.
    def wait_for_spa_load(timeout: 15)
      start_time = Time.current
      loop do
        # Check if the SPA has rendered meaningful content
        ready = browser.evaluate(<<~JS) rescue false
          (function() {
            var body = document.body ? document.body.innerText : '';
            // SPA is loaded when there's more than just the title text
            if (body.trim().length > 50) return true;
            // Or if there are multiple nav/anchor elements (rendered UI)
            var links = document.querySelectorAll('a');
            if (links.length > 3) return true;
            return false;
          })()
        JS

        return true if ready
        return false if Time.current - start_time > timeout

        sleep 1
      end
    end

    def search_supplier_catalog(term, max: 20)
      # The Cut+Dry platform uses an in-page search on the /place-order page.
      # Navigate there on first search, then reuse for subsequent searches.
      ensure_on_order_page

      # Find the search input and type the search term + Enter
      search_input = browser.at_css("input[placeholder*='Search']")
      unless search_input
        logger.warn "[WhatChefsWant] Search input not found on order page"
        return []
      end

      logger.info "[WhatChefsWant] Searching for: #{term}"
      search_input.focus
      search_input.type(term, :clear)
      sleep 0.5
      browser.keyboard.type(:enter)
      sleep 4

      # The catalog results appear as text in the page. DOM elements may be
      # inside an iframe or shadow DOM, so we parse from document.body.innerText.
      page_text = browser.evaluate("document.body ? document.body.innerText : ''") rescue ""

      # Extract products from the "Catalog Results" section
      products = parse_catalog_results(page_text, max: max)
      logger.info "[WhatChefsWant] Found #{products.size} products for '#{term}'"

      # Clear search for next term
      begin
        search_input.focus
        browser.keyboard.type([:control, "a"])
        browser.keyboard.type(:backspace)
        sleep 0.5
      rescue => e
        logger.debug "[WhatChefsWant] Could not clear search: #{e.message}"
      end

      products
    end

    def ensure_on_order_page
      current = browser.current_url rescue ""
      return if current.include?("place-order")

      logger.info "[WhatChefsWant] Navigating to order page"
      navigate_to("#{PLATFORM_URL}/place-order")
      wait_for_spa_load(timeout: 10)
      sleep 2
    end

    # Parse product data from the page text output of Cut+Dry catalog search.
    # Format for each product block:
    #   Product Name
    #   Brand (optional)
    #   Pack Size | #ItemCode
    #   Unit Type (Case/Each/Pound)
    #   $Price
    #   Add to Cart
    def parse_catalog_results(text, max: 20)
      products = []

      # Only parse from "Catalog Results" section onwards
      catalog_section = text.split("Catalog Results").last
      return products unless catalog_section

      # Stop at "Don't Forget to Order" if present (recommended items section)
      catalog_section = catalog_section.split("Don't Forget to Order").first || catalog_section

      # Split by "Add to Cart" to get individual product blocks
      blocks = catalog_section.split("Add to Cart")

      blocks.first(max).each do |block|
        lines = block.strip.split("\n").map(&:strip).reject(&:blank?)
        next if lines.size < 3

        # Find the line with item code: contains "| #" pattern
        code_line_idx = lines.index { |l| l.include?("| #") || l.match?(/#\d{3,}/) }
        next unless code_line_idx

        code_line = lines[code_line_idx]
        # Extract item code from "2/5LB CS | #33354" or just "#33354"
        sku_match = code_line.match(/#(\d+)/)
        next unless sku_match

        sku = sku_match[1]

        # Product name is above the code line
        name = lines[0..([code_line_idx - 1, 0].max)].first
        next if name.blank? || name.length < 3

        # Brand might be the line between name and code
        brand = nil
        if code_line_idx >= 2
          brand = lines[code_line_idx - 1]
        end

        # Pack size from the code line (everything before | #)
        pack_size = code_line.split("|").first&.strip

        # Find price line: starts with $ or contains $/
        price_line = lines.find { |l| l.match?(/\$[\d,.]+/) }
        price = nil
        if price_line
          # Handle "$7.50/lb ($195.00/cs)" - take the per-unit price
          price_match = price_line.match(/\$([\d,.]+)/)
          price = price_match[1].gsub(",", "").to_f if price_match
        end

        # Find unit type (Case, Each, Pound)
        unit_line = lines.find { |l| l.match?(/^(Case|Each|Pound|Gallon|Bag|Box)$/i) }
        unit = unit_line&.strip

        # Check if product is available
        in_stock = !block.include?("Currently not available")

        # Full name with brand
        full_name = brand.present? ? "#{name} #{brand}".truncate(255) : name.truncate(255)

        products << {
          supplier_sku: sku,
          supplier_name: full_name,
          current_price: price,
          pack_size: [pack_size, unit].compact.join(" - "),
          supplier_url: nil,
          in_stock: in_stock,
          category: nil,
          scraped_at: Time.current
        }
      rescue => e
        logger.debug "[WhatChefsWant] Failed to parse product block: #{e.message}"
      end

      products
    end

    def scrape_product(sku)
      navigate_to("#{PLATFORM_URL}/products/#{sku}")

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
