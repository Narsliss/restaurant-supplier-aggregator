module Scrapers
  class ChefsWarehouseScraper < BaseScraper
    BASE_URL = "https://www.chefswarehouse.com".freeze
    ORDER_URL = "https://order.chefswarehouse.com".freeze
    ORDER_MINIMUM = 200.00

    # Broad selectors — the site is a JS SPA, so we try many patterns
    EMAIL_SELECTORS = [
      "#email", "#username", "#loginEmail", "#userEmail",
      "input[name='email']", "input[name='username']", "input[name='loginId']",
      "input[type='email']", "input[placeholder*='email' i]",
      "input[placeholder*='username' i]", "input[aria-label*='email' i]"
    ].freeze

    PASSWORD_SELECTORS = [
      "#password", "#loginPassword", "#userPassword",
      "input[name='password']", "input[type='password']",
      "input[placeholder*='password' i]", "input[aria-label*='password' i]"
    ].freeze

    SUBMIT_SELECTORS = [
      ".btn-sign-in",
      "button.btn-sign-in",
      "button[type='submit'].btn-secondary",
      ".login-btn", ".sign-in-button", ".btn-login", ".login-button",
      "button[data-testid*='login' i]", "button[data-testid*='sign' i]"
    ].freeze

    LOGGED_IN_SELECTORS = [
      ".account-menu", ".user-nav", ".my-account-link", ".account-dropdown",
      ".user-menu", ".logged-in", ".user-greeting",
      "[data-testid='account']", "[data-testid='user-menu']",
      "a[href*='my-account']", "a[href*='dashboard']",
      "a[href*='logout']", "a[href*='sign-out']", "button[aria-label*='account' i]",
      ".header-account", "#account-menu", "#user-nav"
    ].freeze

    def login
      with_browser do
        logger.info "[ChefsWarehouse] Starting login for #{credential.username}"

        # Determine the best login URL
        login_url = credential.supplier.login_url.presence || "#{BASE_URL}/login"
        logger.info "[ChefsWarehouse] Using login URL: #{login_url}"

        # Try restoring session first
        if restore_session
          navigate_to(BASE_URL)
          sleep 2 # Allow SPA to render
          if logged_in?
            logger.info "[ChefsWarehouse] Restored session successfully"
            return true
          end
          logger.info "[ChefsWarehouse] Session restore failed, proceeding with fresh login"
        end

        # Navigate to login page
        navigate_to(login_url)
        sleep 3 # Extra wait for SPA rendering
        logger.info "[ChefsWarehouse] On login page: #{browser.current_url}"

        # Check if we got redirected
        if browser.current_url != login_url
          logger.info "[ChefsWarehouse] Redirected to: #{browser.current_url}"
        end

        # Discover the login form — wait for any input to appear
        email_field = discover_field(EMAIL_SELECTORS, "email/username")
        unless email_field
          # Try waiting longer — SPA might still be loading
          sleep 3
          email_field = discover_field(EMAIL_SELECTORS, "email/username")
        end

        unless email_field
          dump = capture_page_diagnostics
          raise AuthenticationError, "Login form not found. #{dump}"
        end

        password_field = discover_field(PASSWORD_SELECTORS, "password")
        unless password_field
          dump = capture_page_diagnostics
          raise AuthenticationError, "Password field not found. #{dump}"
        end

        # Fill credentials
        fill_element(email_field, credential.username, "email")
        fill_element(password_field, credential.password, "password")
        logger.info "[ChefsWarehouse] Credentials entered, looking for submit button"

        # Find and click submit
        submit_btn = discover_field(SUBMIT_SELECTORS, "submit button")
        if submit_btn
          begin
            submit_btn.click
          rescue => e
            logger.debug "[ChefsWarehouse] Native click failed, using JS: #{e.message}"
            submit_btn.evaluate("this.click()")
          end
        else
          # Fallback: try pressing Enter on the password field
          logger.info "[ChefsWarehouse] No submit button found, pressing Enter on password field"
          password_field.focus rescue nil
          browser.keyboard.type(:Enter)
        end

        logger.info "[ChefsWarehouse] Form submitted, waiting for response..."
        wait_for_page_load
        sleep 4 # Extra wait for SPA navigation after login

        logger.info "[ChefsWarehouse] Post-login URL: #{browser.current_url}"

        # Check for login success — multiple strategies
        if logged_in?
          save_session
          credential.mark_active!
          logger.info "[ChefsWarehouse] Login successful"
          true
        elsif url_indicates_login_success?
          save_session
          credential.mark_active!
          logger.info "[ChefsWarehouse] Login successful (detected via URL change)"
          true
        else
          full_error = diagnose_login_failure
          credential.mark_failed!(full_error)
          raise AuthenticationError, full_error
        end
      end
    end

    def logged_in?
      # Check for authenticated-only elements
      LOGGED_IN_SELECTORS.each do |selector|
        return true if browser.at_css(selector)
      end

      # If the page has a "Log In" or "Sign Up" link, we are NOT logged in
      has_login_link = browser.at_css("a.log-in, a.sign-in, a[href*='/login']")
      has_signup_link = browser.at_css("a.sign-up, a[href*='/sign-up']")
      if has_login_link || has_signup_link
        logger.debug "[ChefsWarehouse] Login/signup links found — not logged in"
        return false
      end

      # Check page text for logged-in indicators (exclude the login page itself)
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 3000)") rescue ""
      is_login_page = body_text.match?(/forgot password|create an account|sign in|stay signed in/i)
      return false if is_login_page

      # Positive signals from page text
      return true if body_text.match?(/my account|order guide|sign out|log ?out|my orders/i)

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
      login_url = credential.supplier.login_url.presence || "#{BASE_URL}/login"
      navigate_to(login_url)
      sleep 3

      email_field = discover_field(EMAIL_SELECTORS, "email/username")
      password_field = discover_field(PASSWORD_SELECTORS, "password")

      if email_field && password_field
        fill_element(email_field, credential.username, "email")
        fill_element(password_field, credential.password, "password")

        submit_btn = discover_field(SUBMIT_SELECTORS, "submit button")
        if submit_btn
          submit_btn.click rescue submit_btn.evaluate("this.click()")
        else
          browser.keyboard.type(:Enter)
        end
      end

      wait_for_page_load
      sleep 3
    end

    private

    # ── Field discovery ─────────────────────────────────────────────
    # Iterates an array of CSS selectors, returns the first visible element found
    def discover_field(selectors, label)
      selectors.each do |sel|
        begin
          elements = browser.css(sel)
          elements.each do |el|
            visible = el.evaluate(<<~JS) rescue false
              var s = window.getComputedStyle(this);
              s.display !== 'none' && s.visibility !== 'hidden' &&
              s.opacity !== '0' && this.offsetWidth > 0 && this.offsetHeight > 0
            JS

            if visible
              logger.info "[ChefsWarehouse] Found #{label} field via '#{sel}'"
              return el
            end
          end
        rescue => e
          logger.debug "[ChefsWarehouse] Selector '#{sel}' raised: #{e.message}"
        end
      end

      # Fallback: try to find ANY input by scanning all inputs on page
      if label.include?("email") || label.include?("username")
        fallback = browser.evaluate(<<~JS) rescue nil
          (function() {
            var inputs = document.querySelectorAll('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])');
            for (var i = 0; i < inputs.length; i++) {
              var inp = inputs[i];
              var t = (inp.type || '').toLowerCase();
              var n = (inp.name || '').toLowerCase();
              var p = (inp.placeholder || '').toLowerCase();
              if (t === 'email' || n.includes('email') || n.includes('user') || p.includes('email') || p.includes('user')) {
                return { found: true, index: i, type: t, name: inp.name, placeholder: inp.placeholder };
              }
            }
            // If no match, return info about the first text/email input
            for (var i = 0; i < inputs.length; i++) {
              var t = (inputs[i].type || '').toLowerCase();
              if (t === 'text' || t === 'email' || t === '') {
                return { found: true, index: i, type: t, name: inputs[i].name, isGuess: true };
              }
            }
            return { found: false, inputCount: inputs.length };
          })()
        JS

        if fallback && fallback["found"]
          all_inputs = browser.css('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])')
          idx = fallback["index"]
          if idx && idx < all_inputs.length
            el = all_inputs[idx]
            guess_note = fallback["isGuess"] ? " (best guess)" : ""
            logger.info "[ChefsWarehouse] Found #{label} field via JS scan: type=#{fallback['type']}, name=#{fallback['name']}#{guess_note}"
            return el
          end
        end
      end

      if label.include?("password")
        pw_el = browser.at_css("input[type='password']") rescue nil
        if pw_el
          logger.info "[ChefsWarehouse] Found password field via type='password' fallback"
          return pw_el
        end
      end

      logger.warn "[ChefsWarehouse] Could not find #{label} field with any selector"
      nil
    end

    # ── Fill a specific element with value ──────────────────────────
    def fill_element(element, value, label)
      begin
        element.focus
        element.type(value, :clear)
        logger.info "[ChefsWarehouse] Filled #{label} via focus+type"
      rescue => e
        logger.debug "[ChefsWarehouse] focus+type failed for #{label}: #{e.message}"
        begin
          element.click
          element.type(value, :clear)
          logger.info "[ChefsWarehouse] Filled #{label} via click+type"
        rescue => e2
          logger.debug "[ChefsWarehouse] click+type failed for #{label}: #{e2.message}"
          element.evaluate("this.value = ''")
          element.evaluate("this.value = '#{value.gsub("'", "\\\\'")}'")
          element.evaluate("this.dispatchEvent(new Event('input', { bubbles: true }))")
          element.evaluate("this.dispatchEvent(new Event('change', { bubbles: true }))")
          logger.info "[ChefsWarehouse] Filled #{label} via JS value assignment"
        end
      end
    end

    # ── URL-based login detection ───────────────────────────────────
    def url_indicates_login_success?
      current = browser.current_url.to_s.downcase rescue ""
      # Only count as success if we're on a known authenticated-only page
      success_patterns = %w[/dashboard /account /my-account /orders /order-guide]
      success_patterns.any? { |p| current.include?(p) }
    end

    # ── Full page diagnostic dump ───────────────────────────────────
    def capture_page_diagnostics
      url = browser.current_url rescue "unknown"
      title = browser.evaluate("document.title") rescue "unknown"

      # Get all input fields on the page for debugging
      inputs_info = browser.evaluate(<<~JS) rescue "could not enumerate inputs"
        (function() {
          var inputs = document.querySelectorAll('input, select, textarea, button');
          var info = [];
          for (var i = 0; i < inputs.length && i < 20; i++) {
            var el = inputs[i];
            var s = window.getComputedStyle(el);
            var visible = s.display !== 'none' && s.visibility !== 'hidden' && el.offsetWidth > 0;
            info.push({
              tag: el.tagName,
              type: el.type || '',
              name: el.name || '',
              id: el.id || '',
              placeholder: el.placeholder || '',
              className: (el.className || '').toString().substring(0, 60),
              visible: visible
            });
          }
          return JSON.stringify(info);
        })()
      JS

      # Get page body text snippet
      body_text = browser.evaluate("document.body?.innerText?.substring(0, 500)") rescue ""

      # Get all iframes (login might be in an iframe)
      iframes_info = browser.evaluate(<<~JS) rescue "none"
        (function() {
          var frames = document.querySelectorAll('iframe');
          var info = [];
          for (var i = 0; i < frames.length; i++) {
            info.push({ src: frames[i].src || '', id: frames[i].id || '', name: frames[i].name || '' });
          }
          return JSON.stringify(info);
        })()
      JS

      parts = [
        "URL: #{url}",
        "Title: '#{title}'",
        "Page inputs: #{inputs_info}",
        "Iframes: #{iframes_info}",
        "Page text: #{body_text.to_s.strip.truncate(300)}"
      ]

      parts.join(" | ")
    end

    # ── Product scraping ────────────────────────────────────────────
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

    # ── Catalog search ──────────────────────────────────────────────
    def search_supplier_catalog(term, max: 20)
      encoded = CGI.escape(term)
      navigate_to("#{BASE_URL}/search?q=#{encoded}")
      sleep 4 # SPA rendering time

      # CW stores product data as JSON in hidden inputs with data-object attribute
      products = extract_products_from_data_objects(max)

      # Fallback: parse visible .product-item elements
      if products.empty?
        products = extract_products_from_items(max)
      end

      products
    end

    # Primary extraction: CW embeds JSON in hidden input[data-sku][data-object]
    def extract_products_from_data_objects(max)
      raw = browser.evaluate(<<~JS) rescue []
        (function() {
          var results = [];
          var inputs = document.querySelectorAll("input[data-sku][data-object]");
          for (var i = 0; i < inputs.length && results.length < #{max}; i++) {
            try {
              var obj = JSON.parse(inputs[i].getAttribute("data-object"));
              if (obj && obj.sku && obj.name) {
                results.push({
                  sku: obj.sku,
                  name: (obj.brand ? obj.name + " - " + obj.brand : obj.name).substring(0, 255),
                  price: obj.price || null,
                  price_info: obj.price_info || "",
                  url: obj.url || "",
                  in_stock: true
                });
              }
            } catch(e) {}
          }
          return results;
        })()
      JS

      (raw || []).map do |item|
        pack = item["price_info"].to_s.gsub(/\$[\d,.]+\s*/, "").strip.presence
        {
          supplier_sku: item["sku"],
          supplier_name: item["name"],
          current_price: item["price"].is_a?(Numeric) ? item["price"] : nil,
          pack_size: pack,
          in_stock: item["in_stock"] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    end

    # Fallback: parse visible .product-item divs
    def extract_products_from_items(max)
      raw = browser.evaluate(<<~JS) rescue []
        (function() {
          var results = [];
          var items = document.querySelectorAll(".product-item");
          for (var i = 0; i < items.length && results.length < #{max}; i++) {
            var text = items[i].innerText.trim();
            var lines = text.split("\\n").map(function(l) { return l.trim(); }).filter(Boolean);
            if (lines.length < 3) continue;

            var name = lines[0] || "";
            var brand = lines.length > 2 ? lines[1] : "";
            var sku = "";
            var price = null;
            var pack = "";

            for (var j = 0; j < lines.length; j++) {
              var line = lines[j];
              if (line.match(/^[A-Z0-9]{2,}$/i) && !line.match(/add to cart/i)) sku = line;
              if (line.match(/^\\$/)) {
                var m = line.match(/[\\d,.]+/);
                if (m) price = parseFloat(m[0].replace(/,/g, ""));
              }
              if (line.match(/\\d+x\\d+|LB|OZ|CS|EA|CT|GAL/i) && !line.match(/^\\$/)) pack = line;
            }

            if (name && name.length > 2) {
              var fullName = brand ? name + " - " + brand : name;
              results.push({sku: sku || name.toLowerCase().replace(/[^a-z0-9]+/g, "-"), name: fullName.substring(0, 255), price: price, pack: pack, in_stock: true});
            }
          }
          return results;
        })()
      JS

      (raw || []).map do |item|
        {
          supplier_sku: item["sku"],
          supplier_name: item["name"],
          current_price: item["price"].is_a?(Numeric) ? item["price"] : nil,
          pack_size: item["pack"].presence,
          in_stock: item["in_stock"] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    end

    # ── Checkout helpers ────────────────────────────────────────────
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
