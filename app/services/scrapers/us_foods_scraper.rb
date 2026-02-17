module Scrapers
  class UsFoodsScraper < BaseScraper
    BASE_URL = 'https://order.usfoods.com'.freeze
    ORDER_MINIMUM = 250.00

    # Azure AD B2C login selectors
    USERID_FIELD = '#signInName-facade'.freeze
    PASSWORD_FIELD = '#passwordInput'.freeze
    SUBMIT_BTN = "button#next[type='submit']".freeze

    # MFA selectors (B2C shows MFA selection after valid User ID)
    MFA_HEADER = '#mfa-select-modal-modal-header-text'.freeze
    MFA_TEXT_OPTION = '#mfa-selector-option-text'.freeze
    MFA_EMAIL_OPTION = '#mfa-selector-option-email'.freeze
    MFA_CODE_INPUTS = (1..6).map { |i| "#code#{i}" }.freeze

    LOGGED_IN_SELECTORS = [
      "ion-button[class*='account']", "ion-icon[name*='person']",
      "a[href*='my-account']", "a[href*='/account']",
      '.account-menu', '.user-nav', '.my-account-link',
      "[data-testid='user-menu']", "[data-testid='account']",
      "a[href*='logout']", "a[href*='sign-out']"
    ].freeze

    # US Foods uses CloudFront WAF that blocks standard headless Chrome.
    # Override with stealth browser options to avoid bot detection.
    # The user-agent must match the actual platform (Linux in Docker, Mac locally).
    def with_browser
      ua = if ENV['BROWSER_PATH'].present? || Rails.env.production?
             # Docker/Railway: Debian Chromium on Linux — UA must match platform
             'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
           else
             'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
           end

      browser_opts = {
        headless: 'new',
        timeout: 60,
        process_timeout: 30,
        window_size: [1920, 1080],
        browser_options: {
          "no-sandbox": true,
          "disable-gpu": true,
          "disable-dev-shm-usage": true,
          "disable-blink-features": 'AutomationControlled',
          "user-agent": ua,
          # Additional stealth flags to reduce bot fingerprint
          "disable-features": 'AutomationControlled,TranslateUI',
          "excludeSwitches": 'enable-automation',
          "disable-ipc-flooding-protection": true,
          "disable-background-networking": false,
          "enable-features": 'NetworkService,NetworkServiceInProcess'
        }
      }

      browser_opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?

      @browser = Ferrum::Browser.new(**browser_opts)

      # Inject stealth scripts via CDP so they run BEFORE any page JS on every navigation.
      # This is critical — WAFs check navigator.webdriver on initial page load,
      # before our post-load apply_stealth can run.
      begin
        stealth_js = <<~JS
          // Hide webdriver flag
          Object.defineProperty(navigator, 'webdriver', {get: () => false});
          // Fix plugins (empty = headless signal)
          Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
          // Fix languages
          Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
          // Add chrome.runtime
          if (!window.chrome) window.chrome = {};
          if (!window.chrome.runtime) window.chrome.runtime = {};
        JS
        browser.command('Page.addScriptToEvaluateOnNewDocument', source: stealth_js)
      rescue StandardError => e
        logger.warn "[UsFoods] CDP stealth injection failed: #{e.message}"
      end

      yield(browser)
    ensure
      browser&.quit
    end

    # Apply comprehensive stealth patches after each page navigation.
    # Must be called after a page loads (needs JS context).
    # Covers the most common WAF fingerprinting checks beyond just webdriver.
    def apply_stealth
      browser.evaluate(<<~JS)
        (function() {
          // Hide webdriver flag
          Object.defineProperty(navigator, 'webdriver', {get: () => false});

          // Fix navigator.plugins (headless Chrome has empty plugins array)
          Object.defineProperty(navigator, 'plugins', {
            get: () => [1, 2, 3, 4, 5]
          });

          // Fix navigator.languages
          Object.defineProperty(navigator, 'languages', {
            get: () => ['en-US', 'en']
          });

          // Add chrome.runtime to mimic real Chrome
          if (!window.chrome) window.chrome = {};
          if (!window.chrome.runtime) window.chrome.runtime = {};

          // Fix permissions query for notifications
          const originalQuery = window.navigator.permissions.query;
          window.navigator.permissions.query = (parameters) =>
            parameters.name === 'notifications'
              ? Promise.resolve({state: Notification.permission})
              : originalQuery(parameters);

          // Spoof WebGL vendor and renderer to avoid "SwiftShader" headless signal
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

    # US Foods stores auth tokens in localStorage/sessionStorage (Ionic SPA),
    # not just cookies. Override save/restore to capture all storage.
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
      logger.info "[UsFoods] Session saved (cookies: #{cookies.size}, localStorage: #{local_storage.size}, sessionStorage: #{session_storage.size})"
    end

    def restore_session
      return false unless credential.session_data.present?
      # US Foods B2C tokens typically last 24h. Use a wider validity window
      # than the default 1 hour to avoid unnecessary MFA re-auth.
      # Extended to 20 hours to cover overnight gaps between cron runs.
      return false unless credential.last_login_at.present? && credential.last_login_at > 20.hours.ago

      begin
        data = JSON.parse(credential.session_data)

        # Handle both old format (flat cookies) and new format (nested blob)
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
        browser.goto(BASE_URL)
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

        logger.info "[UsFoods] Session restored (cookies: #{cookies.size}, localStorage: #{local_storage.size}, sessionStorage: #{session_storage.size})"
        true
      rescue JSON::ParserError => e
        logger.warn "[UsFoods] Failed to parse session data: #{e.message}"
        false
      end
    end

    def login
      with_browser do
        navigate_to(BASE_URL)

        if restore_session
          browser.refresh
          sleep 2
          if logged_in?
            # Session is still valid - refresh the timestamp to extend validity
            save_session
            return true
          end
          logger.info '[UsFoods] Session restore failed, doing fresh login'
        end

        perform_login_steps
        sleep 3

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          error_msg = diagnose_login_failure
          credential.mark_failed!(error_msg)
          raise AuthenticationError, error_msg
        end
      end
    end

    # Soft refresh - just verify session is still valid without triggering full login/MFA
    # Used by session refresh jobs to extend session lifetime without re-authentication
    def soft_refresh
      with_browser do
        if restore_session
          browser.refresh
          sleep 2
          if logged_in?
            save_session
            logger.info '[UsFoods] Soft refresh successful - session extended'
            return true
          end
        end
        logger.info '[UsFoods] Soft refresh failed - session expired'
        false
      end
    end

    def logged_in?
      LOGGED_IN_SELECTORS.any? do |sel|
        browser.at_css(sel)
      rescue StandardError
        false
      end
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

    # US Foods catalog import strategy:
    # 1. Browse each product category via search2?facetFilters=ec_category:X
    # 2. Scroll to load more products within each category page
    # 3. Also run keyword searches for additional coverage
    # This gives much better coverage than keyword search alone.
    # Top-level categories plus key subcategories for deeper coverage.
    # Subcategories are separated by | in the US Foods facet hierarchy.
    USFOODS_CATEGORIES = [
      'Beef',
      'Beverages',
      'Dairy and Eggs',
      'Dry Storage',
      'Fresh Produce',
      'Frozen Foods',
      'Pork',
      'Poultry',
      'Prepared Foods and Deli',
      'Seafood',
      'Specialty Meats',
      # Key subcategories that may not load fully from top-level browsing
      'Beef|Ground Beef',
      'Beef|Steaks',
      'Fresh Produce|Vegetables',
      'Fresh Produce|Fruits',
      'Seafood|Shellfish',
      'Seafood|Fin Fish',
      'Frozen Foods|Frozen Vegetables',
      'Frozen Foods|Frozen Fruits',
      'Frozen Foods|Frozen Desserts',
      'Dairy and Eggs|Cheese',
      'Dairy and Eggs|Milk and Cream',
      'Dairy and Eggs|Eggs',
      'Dairy and Eggs|Butter and Margarine',
      'Dry Storage|Canned Goods',
      'Dry Storage|Pasta and Grains',
      'Dry Storage|Sauces and Condiments',
      'Dry Storage|Spices and Seasonings',
      'Specialty Meats|Veal',
      'Specialty Meats|Lamb',
      'Specialty Meats|Game',
      'Prepared Foods and Deli|Soups',
      'Prepared Foods and Deli|Salads',
      'Poultry|Turkey',
      'Poultry|Chicken',
      'Poultry|Duck'
    ].freeze

    def scrape_catalog(search_terms, max_per_term: 50)
      results = []

      with_browser do
        # Try restoring session first to avoid MFA on every import
        session_restored = false
        if restore_session
          browser.refresh
          sleep 3
          if logged_in?
            logger.info '[UsFoods] Session restored successfully — skipping MFA login'
            session_restored = true
          else
            logger.info '[UsFoods] Session restore failed (not logged in), doing fresh login'
          end
        end

        unless session_restored
          perform_login_steps
          sleep 3
          raise AuthenticationError, 'Could not log in for catalog import' unless logged_in?
        end

        save_session

        # Phase 1: Browse each category and subcategory for broad coverage
        logger.info "[UsFoods] Phase 1: Browsing #{USFOODS_CATEGORIES.size} categories"
        USFOODS_CATEGORIES.each do |category|
          begin
            products = browse_category(category)
            # Tag products with their category for better classification
            display_name = category.include?('|') ? category.split('|').last : category
            products.each { |p| p[:category] ||= display_name }
            results.concat(products)
            logger.info "[UsFoods] Category '#{category}': #{products.size} products (total: #{results.size})"
          rescue StandardError => e
            logger.warn "[UsFoods] Category browse failed for '#{category}': #{e.class}: #{e.message}"
          end
          rate_limit_delay
        end

        # Optimization: If categories yielded enough products, limit search phase
        category_target = 800
        search_phase_limit = nil
        if results.size >= category_target
          search_phase_limit = 15
          logger.info "[UsFoods] Categories yielded #{results.size} products (target: #{category_target}). Limiting search phase to #{search_phase_limit} terms."
        else
          logger.info "[UsFoods] Categories yielded #{results.size} products (below target #{category_target}). Running full search phase."
        end

        # Phase 2: Also run keyword searches for items that may not be in main categories
        terms_to_search = search_phase_limit ? search_terms.first(search_phase_limit) : search_terms
        logger.info "[UsFoods] Phase 2: Searching with #{terms_to_search.size} terms"

        navigate_to("#{BASE_URL}/desktop/search/browse")
        sleep 3

        terms_to_search.each do |term|
          begin
            products = search_supplier_catalog(term, max: max_per_term)
            results.concat(products)
            logger.info "[UsFoods] Search '#{term}': #{products.size} products"
          rescue StandardError => e
            logger.warn "[UsFoods] Search failed for '#{term}': #{e.class}: #{e.message}"
          end
          rate_limit_delay
        end

        # Refresh session at end of successful scrape to extend validity for next cron run
        save_session if results.any?
      end

      # De-duplicate by SKU
      deduped = results.uniq { |r| r[:supplier_sku] }
      logger.info "[UsFoods] Total unique products: #{deduped.size} (from #{results.size} raw)"
      deduped
    end

    # US Foods uses an Order-based workflow:
    # 1. Search for product → Enter quantity → Click "Add To List" button
    # 2. Modal appears with "Create new order" or "Add to existing order" options
    # 3. Select delivery date and click "Add Product"
    # 4. Repeat for each item

    def add_to_cart(items, delivery_date: nil)
      @target_delivery_date = delivery_date

      with_browser do
        # Restore session and navigate to check if logged in
        if restore_session
          navigate_to(BASE_URL)
          sleep 2
          unless logged_in?
            logger.info '[UsFoods] Session invalid, performing fresh login'
            perform_login_steps
            save_session
          end
        else
          logger.info '[UsFoods] No session to restore, performing login'
          perform_login_steps
          save_session
        end

        logger.info "[UsFoods] Logged in, starting add-to-cart for #{items.size} items"
        logger.info "[UsFoods] Target delivery date: #{@target_delivery_date || 'default'}"

        added_items = []
        failed_items = []
        first_item = true

        items.each do |item|
          begin
            add_item_to_order(item[:sku], item[:quantity], create_new_order: first_item)
            added_items << item
            logger.info "[UsFoods] Added SKU #{item[:sku]} qty #{item[:quantity]} to order"
            first_item = false # Subsequent items go to existing order
          rescue StandardError => e
            logger.warn "[UsFoods] Failed to add SKU #{item[:sku]}: #{e.message}"
            failed_items << { sku: item[:sku], error: e.message }
          end
          rate_limit_delay
        end

        if failed_items.any? && added_items.empty?
          raise ItemUnavailableError.new(
            'All items failed to add to order',
            items: failed_items
          )
        end

        logger.info "[UsFoods] Added #{added_items.size} items to order (#{failed_items.size} failed)"
        { added: added_items.size, failed: failed_items }
      end
    end

    # Add a single item to an order via US Foods search → modal flow
    def add_item_to_order(sku, quantity, create_new_order: false)
      # Search for the product
      navigate_to("#{BASE_URL}/desktop/search2?searchText=#{sku}")
      sleep 3

      # Verify product was found
      page_text = begin
        browser.evaluate('document.body.innerText')
      rescue StandardError
        ''
      end
      if page_text.include?("couldn't find any matches") || page_text.include?('No results')
        raise ScrapingError, "Product SKU #{sku} not found"
      end

      # Set quantity in the input field
      qty_set = browser.evaluate(<<~JS)
        (function() {
          // Find the quantity input - US Foods uses ion-input with class "quantity-input-box"
          var ionInput = document.querySelector('ion-input.quantity-input-box');
          if (ionInput) {
            var nativeInput = ionInput.querySelector('input.native-input');
            if (nativeInput) {
              nativeInput.value = '#{quantity}';
              nativeInput.dispatchEvent(new Event('input', { bubbles: true }));
              nativeInput.dispatchEvent(new Event('change', { bubbles: true }));
              ionInput.value = '#{quantity}';
              return true;
            }
          }
          return false;
        })()
      JS

      raise ScrapingError, "Could not set quantity for SKU #{sku}" unless qty_set

      sleep 1

      # Click the "Add To List" button (which opens the order modal)
      clicked = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('ion-button');
          for (var btn of buttons) {
            var text = btn.innerText?.trim();
            if (text === 'Add To List' || text === 'Add to List') {
              // Make sure it's the one in the content area, not header
              var rect = btn.getBoundingClientRect();
              if (rect.top > 150) { // Below header
                btn.click();
                return true;
              }
            }
          }
          // Fallback: click any Add To List button
          for (var btn of buttons) {
            if (btn.innerText?.includes('Add To List') || btn.innerText?.includes('Add to List')) {
              btn.click();
              return true;
            }
          }
          return false;
        })()
      JS

      raise ScrapingError, "Could not find Add To List button for SKU #{sku}" unless clicked

      # Wait for the "Add Product to Order" modal to appear
      sleep 2
      modal_appeared = wait_for_order_modal(timeout: 5)

      unless modal_appeared
        # Modal might not appear if item was added directly
        logger.info '[UsFoods] No modal appeared - item may have been added directly'
        return true
      end

      # Select order type: create new or add to existing
      if create_new_order
        # Click "Create new order"
        browser.evaluate(<<~JS)
          (function() {
            var items = document.querySelectorAll('ion-item, [class*="order-option"]');
            for (var item of items) {
              if (item.innerText && item.innerText.includes('Create new order')) {
                item.click();
                return true;
              }
            }
            return false;
          })()
        JS
        logger.info "[UsFoods] Selected 'Create new order'"

        # Select the delivery date if specified
        sleep 1
        select_delivery_date_in_modal if @target_delivery_date
      else
        # Click "Add to existing order" if available
        browser.evaluate(<<~JS)
          (function() {
            var items = document.querySelectorAll('ion-item, [class*="order-option"]');
            for (var item of items) {
              if (item.innerText && item.innerText.includes('existing order')) {
                item.click();
                return true;
              }
            }
            // Fallback to Create new order if no existing
            for (var item of items) {
              if (item.innerText && item.innerText.includes('Create new order')) {
                item.click();
                return true;
              }
            }
            return false;
          })()
        JS
        logger.info '[UsFoods] Selected existing order (or new if none available)'
      end
      sleep 1

      # Click the "Add Product" button to confirm
      add_product_clicked = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('ion-button, button');
          for (var btn of buttons) {
            var text = btn.innerText?.trim();
            if (text === 'Add Product') {
              btn.click();
              return true;
            }
          }
          return false;
        })()
      JS

      raise ScrapingError, "Could not click 'Add Product' button for SKU #{sku}" unless add_product_clicked

      # Wait for modal to close and confirmation
      sleep 2
      logger.info '[UsFoods] Product added to order'
      true
    end

    # Wait for the "Add Product to Order" modal to appear
    def wait_for_order_modal(timeout: 5)
      start_time = Time.current
      loop do
        modal_visible = begin
          browser.evaluate(<<~JS)
            (function() {
              var modal = document.querySelector('ion-modal, [role="dialog"]');
              if (modal) {
                var text = modal.innerText || '';
                return text.includes('Add Product to Order') ||
                       text.includes('Create new order') ||
                       text.includes('existing order');
              }
              return false;
            })()
          JS
        rescue StandardError
          false
        end
        return true if modal_visible

        return false if Time.current - start_time > timeout

        sleep 0.3
      end
    end

    # Select the delivery date in the order modal calendar
    # The US Foods modal shows a calendar with clickable dates
    def select_delivery_date_in_modal
      return unless @target_delivery_date

      target_date = @target_delivery_date.is_a?(Date) ? @target_delivery_date : Date.parse(@target_delivery_date.to_s)
      target_day = target_date.day
      target_month = target_date.strftime('%B %Y') # e.g., "February 2026"

      logger.info "[UsFoods] Selecting delivery date: #{target_date} (day #{target_day})"

      # First, navigate to the correct month if needed
      # The modal shows month/year like "February 2026" and has < > navigation buttons
      navigate_to_correct_month(target_month)

      # Click on the target day in the calendar
      date_clicked = browser.evaluate(<<~JS)
        (function() {
          // Find calendar day buttons - US Foods uses buttons or divs with day numbers
          var dayElements = document.querySelectorAll(
            '[class*="calendar"] button, ' +
            '[class*="calendar"] [class*="day"], ' +
            'ion-datetime button, ' +
            '[class*="date-picker"] button'
          );

          for (var el of dayElements) {
            var text = el.innerText?.trim();
            // Match the exact day number
            if (text === '#{target_day}' || text === '#{target_day.to_s.rjust(2, '0')}') {
              // Make sure it's not disabled/grayed out
              var isDisabled = el.disabled ||
                              el.classList.contains('disabled') ||
                              el.getAttribute('aria-disabled') === 'true' ||
                              el.classList.contains('unavailable');
              if (!isDisabled) {
                el.click();
                return { clicked: true, day: text };
              }
            }
          }

          // Fallback: try finding by aria-label which often contains the full date
          var allButtons = document.querySelectorAll('button, [role="button"]');
          for (var btn of allButtons) {
            var label = btn.getAttribute('aria-label') || '';
            if (label.toLowerCase().includes('#{target_date.strftime('%B').downcase}') &&
                label.includes('#{target_day}')) {
              btn.click();
              return { clicked: true, method: 'aria-label', label: label };
            }
          }

          return { clicked: false };
        })()
      JS

      if date_clicked && date_clicked['clicked']
        logger.info "[UsFoods] Clicked delivery date: #{date_clicked}"
      else
        logger.warn "[UsFoods] Could not click delivery date #{target_date}, using default"
      end

      sleep 0.5
    end

    # Navigate to the correct month in the calendar
    def navigate_to_correct_month(target_month)
      5.times do |_attempt|
        current_month = begin
          browser.evaluate(<<~JS)
            (function() {
              // Look for month/year display in the calendar
              var monthEl = document.querySelector(
                '[class*="calendar"] [class*="month"], ' +
                '[class*="calendar-header"], ' +
                '[class*="date-picker"] [class*="month"]'
              );
              return monthEl?.innerText?.trim();
            })()
          JS
        rescue StandardError
          nil
        end

        if current_month && current_month.include?(target_month.split(' ').first) # Check month name
          logger.info "[UsFoods] Calendar showing correct month: #{current_month}"
          return
        end

        # Click next month button
        browser.evaluate(<<~JS)
          (function() {
            var nextBtn = document.querySelector(
              '[class*="calendar"] [class*="next"], ' +
              '[class*="calendar"] ion-icon[name*="forward"], ' +
              '[class*="calendar"] button:last-child, ' +
              '[aria-label*="next month"]'
            );
            if (nextBtn) nextBtn.click();
          })()
        JS

        sleep 0.5
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
            'Order minimum not met',
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
        raise DeliveryUnavailableError, 'No delivery dates available for your location' unless delivery_date_available?

        # Place order
        click(".place-order-button, .submit-order, [data-testid='place-order']")
        wait_for_confirmation_or_error

        {
          confirmation_number: extract_text(".confirmation-number, .order-number, [data-testid='confirmation']"),
          total: extract_price(extract_text('.order-total, .total-amount')),
          delivery_date: extract_text('.delivery-date, .estimated-delivery')
        }
      end
    end

    protected

    def perform_login_steps
      # US Foods uses Azure AD B2C with a multi-step flow:
      # 1. order.usfoods.com → click "Log In" ion-button → redirects to Azure B2C
      # 2. Enter User ID → click "Log in"
      # 3. MFA selection (text or email) → enter 6-digit code
      # 4. Redirects back to order.usfoods.com as authenticated

      logger.info "[UsFoods] Starting login for #{credential.username}"

      # Step 1: Navigate to order portal and click the "Log In" ionic button
      navigate_to(BASE_URL)
      sleep 3
      apply_stealth

      # Log the page state for diagnostics (helps debug WAF blocks)
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

      logger.info "[UsFoods] Page loaded — URL: #{current_url}, Title: #{page_title}"

      # Try clicking "Log In" button with retries
      clicked = false
      3.times do |attempt|
        clicked = begin
          browser.evaluate(<<~JS)
            (function() {
              var btns = document.querySelectorAll('ion-button');
              for (var i = 0; i < btns.length; i++) {
                if (btns[i].innerText.trim() === 'Log In') {
                  btns[i].click();
                  return true;
                }
              }
              // Also try standard links/buttons
              var links = document.querySelectorAll('a, button');
              for (var i = 0; i < links.length; i++) {
                var text = (links[i].innerText || '').trim();
                if (text === 'Log In' || text === 'LOG IN' || text === 'Sign In' || text === 'SIGN IN') {
                  links[i].click();
                  return true;
                }
              }
              return false;
            })()
          JS
        rescue StandardError
          false
        end
        break if clicked

        logger.debug "[UsFoods] Login button not found, retrying (attempt #{attempt + 1})"
        sleep 2
      end

      unless clicked
        # Dump page content to logs so we can see what CloudFront/WAF returned
        body_snippet = begin
          browser.evaluate('document.body?.innerText?.substring(0, 800)')
        rescue StandardError
          'could not read body'
        end
        all_buttons = begin
          browser.evaluate(<<~JS)
            (function() {
              var els = document.querySelectorAll('button, a, ion-button, [role="button"]');
              var info = [];
              for (var i = 0; i < els.length && i < 20; i++) {
                info.push(els[i].tagName + ':' + (els[i].innerText || '').trim().substring(0, 40));
              }
              return info.join(' | ');
            })()
          JS
        rescue StandardError
          'could not read buttons'
        end
        logger.error "[UsFoods] Login button not found after 3 attempts. URL: #{current_url}"
        logger.error "[UsFoods] Page title: #{page_title}"
        logger.error "[UsFoods] Page body: #{body_snippet}"
        logger.error "[UsFoods] Buttons on page: #{all_buttons}"
        raise ScrapingError, 'Could not find Log In button on order.usfoods.com'
      end

      # Wait for the Azure B2C login page to load
      logger.info '[UsFoods] Waiting for Azure B2C login page...'
      wait_for_selector(USERID_FIELD, timeout: 30)
      apply_stealth
      logger.info "[UsFoods] Login page loaded at: #{browser.current_url}"

      # Step 2: Enter User ID and submit.
      # B2C uses a facade input (#signInName-facade) that syncs to a hidden
      # input (#signInName). We must fill both and trigger proper events.
      browser.evaluate(<<~JS)
        (function() {
          var facade = document.getElementById('signInName-facade');
          var hidden = document.getElementById('signInName');
          var username = #{credential.username.to_json};

          // Fill facade field with native setter to trigger React/Angular bindings
          if (facade) {
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            nativeSetter.call(facade, username);
            facade.dispatchEvent(new Event('input', { bubbles: true }));
            facade.dispatchEvent(new Event('change', { bubbles: true }));
            facade.dispatchEvent(new Event('blur', { bubbles: true }));
          }

          // Also fill hidden field directly as a safety net
          if (hidden) {
            var nativeSetter2 = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            nativeSetter2.call(hidden, username);
            hidden.dispatchEvent(new Event('input', { bubbles: true }));
            hidden.dispatchEvent(new Event('change', { bubbles: true }));
          }
        })()
      JS
      sleep 0.5

      # Verify the value was set
      hidden_val = begin
        browser.evaluate("document.getElementById('signInName')?.value")
      rescue StandardError
        ''
      end
      logger.info "[UsFoods] User ID set: facade=#{credential.username}, hidden=#{hidden_val}"

      click(SUBMIT_BTN)

      logger.info '[UsFoods] Submitted User ID, waiting for next step...'
      sleep 4

      # Check for User ID error — look for "could not find" in the full page text.
      # Don't check individual B2C elements, as they may contain MFA prompts.
      page_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 1000)')
      rescue StandardError
        ''
      end
      if page_text.downcase.include?('could not find') && page_text.downcase.include?('user id')
        raise AuthenticationError, 'We could not find the User ID that you entered. Please verify and try again.'
      end

      # Step 3: Check what screen we're on — MFA selection or password
      mfa_header = extract_text(MFA_HEADER)
      if mfa_header.present?
        logger.info "[UsFoods] MFA selection screen detected: #{mfa_header}"
        handle_mfa_selection
        return
      end

      # If no MFA, check for password field
      password_visible = begin
        browser.evaluate(<<~JS)
          (function() {
            var el = document.querySelector('#{PASSWORD_FIELD}');
            return el && el.offsetHeight > 0;
          })()
        JS
      rescue StandardError
        false
      end

      if password_visible
        logger.info '[UsFoods] Password field visible, entering password'
        fill_field(PASSWORD_FIELD, credential.password)
        sleep 0.5
        click(SUBMIT_BTN)
        wait_for_redirect_to_usfoods(timeout: 20)
        sleep 2
      else
        # Neither MFA nor password — dump diagnostics
        dump = begin
          browser.evaluate('document.body.innerText.substring(0, 500)')
        rescue StandardError
          'unknown'
        end
        raise ScrapingError, "Unexpected state after User ID submission. Page content: #{dump.truncate(300)}"
      end
    end

    private

    # Handle MFA selection and code entry via Supplier2faRequest (like PPO)
    def handle_mfa_selection
      # Determine available MFA options (buttons have id="Text" and id="Email")
      text_btn = browser.at_css('button#Text')
      email_btn = browser.at_css('button#Email')
      text_phone = extract_text('#mfa-selector-option-text-phone-number')
      email_addr = extract_text('#mfa-selector-option-text-email')
      logger.info "[UsFoods] MFA options — Text: #{text_phone}, Email: #{email_addr}"

      # Prefer email over text for verification
      if email_btn
        mfa_method = 'Email'
        prompt_msg = "US Foods has sent a verification code to #{email_addr}. Please check your email inbox and enter the code below."
      elsif text_btn
        mfa_method = 'Text'
        prompt_msg = "US Foods has sent a verification code via text to #{text_phone}. Please check your messages and enter the code below."
      else
        raise ScrapingError, 'No MFA options found on page'
      end

      # Click the MFA option button
      browser.at_css("button##{mfa_method}").click
      logger.info "[UsFoods] Selected MFA method: #{mfa_method}"
      sleep 5

      # Wait for code input fields to become visible
      wait_for_mfa_code_inputs

      # Create a 2FA request and poll for user-submitted code (like PPO)
      tfa_request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        request_type: 'login',
        status: 'pending',
        prompt_message: prompt_msg,
        expires_at: 5.minutes.from_now
      )
      logger.info "[UsFoods] Created 2FA request ##{tfa_request.id}, waiting for code..."
      credential.update!(two_fa_enabled: true, status: 'pending')

      # Broadcast to ActionCable so the global 2FA modal appears instantly
      TwoFactorChannel.broadcast_to(
        credential.user,
        {
          type: 'two_fa_required',
          request_id: tfa_request.id,
          session_token: tfa_request.session_token,
          supplier_name: credential.supplier.name,
          two_fa_type: 'email',
          prompt_message: prompt_msg,
          expires_at: tfa_request.expires_at.iso8601
        }
      )

      # Poll for user to enter the code via the web UI
      code = poll_for_2fa_code(tfa_request, timeout: 300)

      unless code
        tfa_request.update!(status: 'expired')
        raise AuthenticationError, 'Verification code was not entered in time'
      end

      # Enter the 6-digit code into the B2C code inputs
      logger.info '[UsFoods] Entering MFA code...'
      enter_mfa_code(code)

      # Wait for either redirect (success) or error message
      logger.info '[UsFoods] Code entered, waiting for result...'
      sleep 8

      # Check for wrong code error first
      error_el = browser.at_css('#modal-error')
      if error_el
        error_text = begin
          error_el.text.strip
        rescue StandardError
          ''
        end
        if error_text.present?
          tfa_request.update!(status: 'failed')
          raise AuthenticationError, "MFA verification failed: #{error_text}"
        end
      end

      page_text = begin
        browser.evaluate('document.body.innerText.substring(0, 500)')
      rescue StandardError
        ''
      end
      if page_text.downcase.include?('wrong code') || page_text.downcase.include?('incorrect code') || page_text.downcase.include?('invalid code')
        tfa_request.update!(status: 'failed')
        raise AuthenticationError, 'MFA verification failed: wrong code entered. Please try validating again.'
      end

      tfa_request.update!(status: 'verified')
      logger.info '[UsFoods] MFA code accepted'

      # After MFA, B2C shows a SelfAsserted/confirmed page with a Continue button
      # (id="continue") that must be clicked to complete the flow and redirect back.
      # The button may be a <button>, <input>, or custom element depending on B2C UI.
      click_b2c_continue_button
    end

    # Wait for the 6 individual code input fields to appear
    def wait_for_mfa_code_inputs(timeout: 10)
      start_time = Time.current
      loop do
        visible = begin
          browser.evaluate(<<~JS)
            (function() {
              var el = document.querySelector('#code1');
              return el && el.offsetHeight > 0;
            })()
          JS
        rescue StandardError
          false
        end
        return true if visible

        raise ScrapingError, 'MFA code inputs did not appear' if Time.current - start_time > timeout

        sleep 0.3
      end
    end

    # Enter a 6-digit MFA code into individual input fields (#code1 through #code6).
    # The B2C form auto-advances focus and auto-submits after the 6th digit.
    # We type each digit individually with a small delay to mimic human input.
    def enter_mfa_code(code)
      digits = code.to_s.gsub(/\D/, '').chars.first(6)
      logger.info "[UsFoods] Entering #{digits.length}-digit MFA code"

      digits.each_with_index do |digit, i|
        field = browser.at_css("#code#{i + 1}")
        next unless field

        begin
          field.focus
          field.type(digit, :clear)
        rescue StandardError => e
          logger.debug "[UsFoods] Native type failed for #code#{i + 1}, using JS: #{e.message}"
          browser.evaluate(<<~JS)
            (function() {
              var f = document.querySelector('#code#{i + 1}');
              f.focus();
              f.value = '#{digit}';
              f.dispatchEvent(new Event('input', { bubbles: true }));
              f.dispatchEvent(new Event('change', { bubbles: true }));
            })()
          JS
        end
        sleep 0.3
      end
    end

    # After MFA code is accepted, B2C transitions to a SelfAsserted/confirmed page.
    # This page does NOT auto-redirect — it has a Continue button (typically id="continue")
    # that must be clicked to advance the B2C user journey and redirect back to the app.
    def click_b2c_continue_button
      15.times do |attempt|
        current_url = begin
          browser.current_url
        rescue StandardError
          ''
        end

        # Already redirected back to usfoods.com — done!
        if current_url.include?('usfoods.com') && !current_url.include?('b2clogin.com')
          logger.info "[UsFoods] Redirected to: #{current_url}"
          return
        end

        # Try clicking the B2C Continue button using multiple approaches.
        # B2C's standard Continue button has id="continue" but may be rendered as
        # <button>, <input>, or inside a custom B2C form (#attributeVerification).
        clicked = begin
          browser.evaluate(<<~JS)
            (function() {
              // Approach 1: Direct #continue element (B2C standard)
              var cont = document.getElementById('continue');
              if (cont) {
                cont.removeAttribute('disabled');
                cont.click();
                return '#continue => ' + (cont.tagName || '') + ': ' + (cont.innerText || cont.value || '').trim().substring(0, 30);
              }

              // Approach 2: Any button/input with continue-like text or attributes
              var selectors = [
                'button#continue', '#continueButton', 'button#next',
                'button[type="submit"]', 'input[type="submit"]',
                'button.continue', 'button.btn-primary', '#skipMfa',
                '#attributeVerification button', '#attributeVerification input[type="submit"]'
              ];
              for (var s = 0; s < selectors.length; s++) {
                var els = document.querySelectorAll(selectors[s]);
                for (var i = 0; i < els.length; i++) {
                  var el = els[i];
                  // Click even zero-height elements — B2C may hide them visually
                  el.removeAttribute('disabled');
                  el.click();
                  return selectors[s] + ' => ' + (el.innerText || el.value || '').trim().substring(0, 30);
                }
              }

              // Approach 3: Search all clickable elements for "Continue" text
              var allBtns = document.querySelectorAll('button, input[type="submit"], input[type="button"], a.btn, [role="button"]');
              for (var i = 0; i < allBtns.length; i++) {
                var text = (allBtns[i].innerText || allBtns[i].value || '').trim().toLowerCase();
                if (text === 'continue' || text === 'next' || text === 'proceed' || text === 'submit') {
                  allBtns[i].removeAttribute('disabled');
                  allBtns[i].click();
                  return 'text-match => ' + text;
                }
              }

              // Approach 4: Try form submission on B2C's attributeVerification form
              var form = document.getElementById('attributeVerification');
              if (form && typeof form.submit === 'function') {
                form.submit();
                return 'form#attributeVerification submit';
              }

              return null;
            })()
          JS
        rescue StandardError
          nil
        end

        if clicked
          logger.info "[UsFoods] Clicked B2C Continue: #{clicked} (attempt #{attempt + 1})"
          sleep 4
        else
          # Dump page diagnostics on first failure to help debug
          dump_b2c_page_diagnostics if attempt == 2
          logger.debug "[UsFoods] No Continue button found (attempt #{attempt + 1})"
          sleep 2
        end
      end

      # Final check — if still on B2C, raise an error with diagnostics
      current_url = begin
        browser.current_url
      rescue StandardError
        ''
      end
      return unless current_url.include?('b2clogin.com')

      dump_b2c_page_diagnostics
      raise ScrapingError, "Login did not redirect back to usfoods.com after MFA (stuck at: #{current_url})"
    end

    # Dump the current B2C page content for debugging
    def dump_b2c_page_diagnostics
      current_url = begin
        browser.current_url
      rescue StandardError
        'unknown'
      end
      logger.info '[UsFoods] === B2C Page Diagnostics ==='
      logger.info "[UsFoods] URL: #{current_url}"

      # Dump all elements with IDs
      ids = begin
        browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('[id]');
            var ids = [];
            for (var i = 0; i < els.length; i++) {
              var el = els[i];
              var vis = el.offsetHeight > 0 ? 'visible' : 'hidden';
              ids.push(el.tagName + '#' + el.id + '(' + vis + ')');
            }
            return ids.join(', ');
          })()
        JS
      rescue StandardError
        'error'
      end
      logger.info "[UsFoods] IDs on page: #{ids}"

      # Dump all buttons and inputs
      buttons = begin
        browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('button, input[type="submit"], input[type="button"], a.btn, [role="button"]');
            var info = [];
            for (var i = 0; i < els.length; i++) {
              var el = els[i];
              var vis = el.offsetHeight > 0 ? 'visible' : 'hidden';
              var disabled = el.disabled ? 'disabled' : 'enabled';
              info.push(el.tagName + '[id=' + (el.id || '') + ',type=' + (el.type || '') + ',text=' + (el.innerText || el.value || '').trim().substring(0, 30) + ',' + vis + ',' + disabled + ']');
            }
            return info.join(', ');
          })()
        JS
      rescue StandardError
        'error'
      end
      logger.info "[UsFoods] Buttons/inputs: #{buttons}"

      # Dump visible text (first 500 chars)
      text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 500)')
      rescue StandardError
        'error'
      end
      logger.info "[UsFoods] Page text: #{text}"

      # Dump outer HTML of key elements
      forms = begin
        browser.evaluate(<<~JS)
          (function() {
            var form = document.getElementById('attributeVerification');
            if (form) return form.outerHTML.substring(0, 1000);
            return 'no #attributeVerification form found';
          })()
        JS
      rescue StandardError
        'error'
      end
      logger.info "[UsFoods] Form HTML: #{forms}"
      logger.info '[UsFoods] === End Diagnostics ==='
    end

    # Poll the DB for user-submitted 2FA code (same pattern as PPO scraper)
    def poll_for_2fa_code(tfa_request, timeout: 300)
      start_time = Time.current
      loop do
        tfa_request.reload
        # Check for both 'submitted' and 'verified' status (ActionCable may mark as verified)
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

    # Wait for the browser to redirect back to usfoods.com after B2C auth
    def wait_for_redirect_to_usfoods(timeout: 20)
      start_time = Time.current
      loop do
        current = begin
          browser.current_url
        rescue StandardError
          ''
        end
        return true if current.include?('usfoods.com') && !current.include?('b2clogin.com')

        if Time.current - start_time > timeout
          raise ScrapingError, "Login did not redirect back to usfoods.com (stuck at: #{current})"
        end

        sleep 0.5
      end
    end

    # Browse a US Foods product category via the search2 facet URL.
    # US Foods uses Ionic's ion-infinite-scroll for pagination.
    # We must scroll the ion-content's internal shadow DOM scroll element
    # to trigger the ionInfinite event and load more products.
    def browse_category(category, max_products: 200)
      # Support both top-level categories and subcategory paths (e.g. "Beef|Steaks")
      if category.include?('|')
        parts = category.split('|')
        url = "#{BASE_URL}/desktop/search2?originSearchPage=catalog&facetFilters=ec_category:#{CGI.escape(parts.first)}|#{CGI.escape(parts.last)}"
      else
        url = "#{BASE_URL}/desktop/search2?originSearchPage=catalog&facetFilters=ec_category:#{CGI.escape(category)}"
      end
      navigate_to(url)

      # Wait for the Ionic SPA to render product cards (API call + render can take several seconds)
      begin
        wait_for_selector('ion-card', timeout: 15)
      rescue StandardError
        logger.warn "[UsFoods] No ion-card elements appeared for category '#{category}' after 15s"
        return []
      end

      initial_count = begin
        browser.evaluate("document.querySelectorAll('ion-card').length")
      rescue StandardError
        0
      end
      logger.info "[UsFoods] Category '#{category}': #{initial_count} cards on initial load"

      previous_count = initial_count
      stale_rounds = 0

      20.times do |attempt|
        current_count = begin
          browser.evaluate("document.querySelectorAll('ion-card').length")
        rescue StandardError
          0
        end
        break if current_count >= max_products

        if current_count == previous_count
          stale_rounds += 1
          break if stale_rounds >= 5 # No new products after 5 consecutive attempts
        else
          stale_rounds = 0
        end
        previous_count = current_count

        logger.debug "[UsFoods] Category '#{category}' scroll attempt #{attempt + 1}: #{current_count} cards, #{stale_rounds} stale rounds"

        # Trigger Ionic infinite scroll by scrolling the ion-content's
        # internal scroll element (inside the shadow DOM).
        trigger_ionic_infinite_scroll
        sleep 3
      end

      final_count = begin
        browser.evaluate("document.querySelectorAll('ion-card').length")
      rescue StandardError
        0
      end
      logger.info "[UsFoods] Category '#{category}': #{final_count} cards loaded after scrolling (started with #{initial_count})"

      extract_products_from_page(max_products)
    end

    # Trigger Ionic's infinite scroll by scrolling the ion-content shadow DOM element.
    # ion-content uses a shadow root with an internal .inner-scroll div.
    # ion-infinite-scroll listens for scroll events on that container and fires
    # ionInfinite when the user nears the bottom (threshold ~15%).
    #
    # Uses evaluate_async so Ferrum properly awaits the async Ionic API calls
    # (getScrollElement, scrollToBottom, complete) instead of returning an
    # unresolved Promise.
    def trigger_ionic_infinite_scroll
      browser.evaluate_async(<<~JS, 5)
        var done = arguments[arguments.length - 1];
        try {
          var ionContent = document.querySelector('ion-content');

          // Method 1: Use Ionic's getScrollElement() API to get the real scrollable element
          if (ionContent && typeof ionContent.getScrollElement === 'function') {
            try {
              var scrollEl = await ionContent.getScrollElement();
              if (scrollEl) {
                scrollEl.scrollTop = scrollEl.scrollHeight;
                scrollEl.dispatchEvent(new CustomEvent('scroll', { bubbles: true }));
              }
            } catch(e) {}
          }

          // Method 2: Use ion-content's scrollToBottom which handles shadow DOM internally
          if (ionContent && typeof ionContent.scrollToBottom === 'function') {
            try { await ionContent.scrollToBottom(300); } catch(e) {}
          }

          // Method 3: Directly access shadow root scroll container
          if (ionContent && ionContent.shadowRoot) {
            var innerScroll = ionContent.shadowRoot.querySelector('.inner-scroll');
            if (innerScroll) {
              innerScroll.scrollTop = innerScroll.scrollHeight;
              innerScroll.dispatchEvent(new CustomEvent('scroll', { bubbles: true }));
            }
          }

          // Method 4: Trigger ionInfinite event directly on the infinite scroll element
          var infiniteScroll = document.querySelector('ion-infinite-scroll');
          if (infiniteScroll) {
            if (typeof infiniteScroll.complete === 'function') {
              try { await infiniteScroll.complete(); } catch(e) {}
            }
            infiniteScroll.dispatchEvent(new CustomEvent('ionInfinite', {
              bubbles: true, detail: { complete: function() {} }
            }));
          }

          // Method 5: Standard window scroll as a fallback
          window.scrollTo(0, document.body.scrollHeight);

          done(true);
        } catch(e) {
          done(false);
        }
      JS
    rescue StandardError => e
      logger.debug "[UsFoods] trigger_ionic_infinite_scroll error: #{e.message}"
      nil
    end

    # Search for products by keyword via URL-based search.
    # After initial results load, triggers Ionic infinite scroll to load more.
    def search_supplier_catalog(term, max: 50)
      logger.info "[UsFoods] Searching catalog for: #{term}"

      # Use URL-based search for more reliable results
      navigate_to("#{BASE_URL}/desktop/search2?q=#{CGI.escape(term)}")

      # Wait for the SPA to render at least one product card
      begin
        wait_for_selector('ion-card', timeout: 15)
      rescue StandardError
        logger.warn "[UsFoods] No ion-card elements appeared for search '#{term}' after 15s"
        return []
      end

      initial_count = begin
        browser.evaluate("document.querySelectorAll('ion-card').length")
      rescue StandardError
        0
      end
      logger.info "[UsFoods] Search '#{term}': #{initial_count} cards on initial load"

      # Scroll to load more search results using Ionic infinite scroll
      previous_count = initial_count
      stale_rounds = 0

      15.times do |attempt|
        current_count = begin
          browser.evaluate("document.querySelectorAll('ion-card').length")
        rescue StandardError
          0
        end
        break if current_count >= max

        if current_count == previous_count
          stale_rounds += 1
          break if stale_rounds >= 4
        else
          stale_rounds = 0
        end
        previous_count = current_count

        logger.debug "[UsFoods] Search '#{term}' scroll attempt #{attempt + 1}: #{current_count} cards, #{stale_rounds} stale rounds"

        trigger_ionic_infinite_scroll
        sleep 3
      end

      final_count = begin
        browser.evaluate("document.querySelectorAll('ion-card').length")
      rescue StandardError
        0
      end
      logger.info "[UsFoods] Search '#{term}': #{final_count} cards loaded after scrolling (started with #{initial_count})"

      extract_products_from_page(max)
    end

    # Extract product data from all ion-card elements currently on the page.
    # Used by both browse_category and search_supplier_catalog.
    #
    # US Foods shows TWO prices on product cards:
    #   1. Case price (larger) - the actual price for the pack/case (e.g., "$56.30")
    #   2. Unit price (smaller) - price per unit like "/oz" or "/lb" (e.g., "$0.18/oz")
    # We want the CASE PRICE, not the unit price.
    def extract_products_from_page(max = 100)
      products_json = begin
        browser.evaluate(<<~JS)
          (function() {
            var cards = document.querySelectorAll('ion-card');
            var products = [];
            var limit = #{max};

            for (var i = 0; i < cards.length && products.length < limit; i++) {
              var card = cards[i];
              var text = card.innerText || '';

              // Extract item number (#NNNNNNN) — skip cards without one (sub-category cards)
              var skuMatch = text.match(/#(\\d{5,})/);
              if (!skuMatch) continue;
              var sku = skuMatch[1];

              var brandEl = card.querySelector('[data-cy*="product-brand"]');
              var brand = brandEl ? brandEl.innerText.trim() : '';

              var descEl = card.querySelector('[data-cy="product-description-text"]');
              var desc = descEl ? descEl.innerText.trim() : '';

              var name = brand ? (brand + ' ' + desc) : desc;
              if (!name) continue;

              var packEl = card.querySelector('[data-cy*="product-packsize"]');
              var packSize = packEl ? packEl.innerText.trim() : '';

              // Extract CASE PRICE (not unit price).
              // US Foods shows case price in a larger element, and unit price in smaller text with "/oz", "/lb", etc.
              // Strategy: Look for the price element that does NOT have a unit suffix.
              var price = null;

              // Method 1: Look for data-cy price elements (case price vs unit price)
              var casePriceEl = card.querySelector('[data-cy*="case-price"], [data-cy*="product-price"]:not([data-cy*="unit"])');
              if (casePriceEl) {
                var casePriceText = casePriceEl.innerText || '';
                var casePriceMatch = casePriceText.match(/\\$(\\d+[,\\d]*\\.\\d{2})/);
                if (casePriceMatch) {
                  price = parseFloat(casePriceMatch[1].replace(',', ''));
                }
              }

              // Method 2: Split text by lines/spaces and find prices, excluding unit prices
              // Unit prices have format "$X.XX/oz" or "$X.XX/lb" etc.
              if (!price) {
                // Find all price patterns in the text
                var priceRegex = /\\$(\\d+[,\\d]*\\.\\d{2})(\\/[a-zA-Z]+)?/g;
                var match;
                var casePrices = [];
                var unitPrices = [];

                while ((match = priceRegex.exec(text)) !== null) {
                  var val = parseFloat(match[1].replace(',', ''));
                  if (match[2]) {
                    // Has unit suffix like /oz, /lb - this is a unit price
                    unitPrices.push(val);
                  } else {
                    // No unit suffix - could be case price
                    casePrices.push(val);
                  }
                }

                // Prefer case prices (no unit suffix)
                if (casePrices.length > 0) {
                  // Take the largest case price (in case there are multiple)
                  price = Math.max.apply(null, casePrices);
                }
              }

              // Method 3: Fallback - if no case price found but we have unit prices,
              // the case price might not be showing. Use the largest price overall,
              // but only if it's reasonably large (> $5) to avoid unit prices.
              // Most food service case prices are $5+ (often $20-100+).
              if (!price) {
                var priceMatches = text.match(/\\$(\\d+[,\\d]*\\.\\d{2})/g) || [];
                var allPrices = priceMatches.map(function(p) {
                  return parseFloat(p.replace('$', '').replace(',', ''));
                });
                if (allPrices.length > 0) {
                  var maxPrice = Math.max.apply(null, allPrices);
                  // Only use if it looks like a case price (> $5)
                  // Prices under $5 are almost always per-unit prices
                  if (maxPrice > 5) {
                    price = maxPrice;
                  }
                }
              }

              var inStock = !text.toLowerCase().includes('out of stock') &&
                            !text.toLowerCase().includes('unavailable') &&
                            !card.querySelector('[data-cy*="out-of-stock"]');

              products.push({
                sku: sku,
                brand: brand,
                name: name,
                pack_size: packSize,
                price: price,
                in_stock: inStock
              });
            }

            return JSON.stringify(products);
          })()
        JS
      rescue StandardError
        '[]'
      end

      products = begin
        JSON.parse(products_json)
      rescue StandardError
        []
      end

      products.map do |p|
        {
          supplier_sku: p['sku'],
          supplier_name: p['name']&.truncate(255),
          current_price: p['price'],
          pack_size: p['pack_size'],
          supplier_url: "#{BASE_URL}/desktop/product/#{p['sku']}",
          in_stock: p['in_stock'] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    end

    def scrape_product(sku)
      navigate_to("#{BASE_URL}/desktop/product/#{sku}")
      sleep 3

      product_data = begin
        browser.evaluate(<<~JS)
          (function() {
            var text = document.body?.innerText || '';
            var skuMatch = text.match(/#(\\d{5,})/);
            if (!skuMatch) return null;

            var brandEl = document.querySelector('[data-cy*="product-brand"]');
            var descEl = document.querySelector('[data-cy="product-description-text"]');
            var packEl = document.querySelector('[data-cy*="product-packsize"]');

            var brand = brandEl ? brandEl.innerText.trim() : '';
            var desc = descEl ? descEl.innerText.trim() : '';

            // Extract CASE PRICE (not unit price) - same logic as extract_products_from_page
            var price = null;

            // Method 1: Look for case price element
            var casePriceEl = document.querySelector('[data-cy*="case-price"], [data-cy*="product-price"]:not([data-cy*="unit"])');
            if (casePriceEl) {
              var casePriceText = casePriceEl.innerText || '';
              var casePriceMatch = casePriceText.match(/\\$(\\d+[,\\d]*\\.\\d{2})/);
              if (casePriceMatch) {
                price = parseFloat(casePriceMatch[1].replace(',', ''));
              }
            }

            // Method 2: Split text and find prices, excluding unit prices
            if (!price) {
              var priceRegex = /\\$(\\d+[,\\d]*\\.\\d{2})(\\/[a-zA-Z]+)?/g;
              var match;
              var casePrices = [];

              while ((match = priceRegex.exec(text)) !== null) {
                var val = parseFloat(match[1].replace(',', ''));
                if (!match[2]) {
                  // No unit suffix - could be case price
                  casePrices.push(val);
                }
              }

              if (casePrices.length > 0) {
                price = Math.max.apply(null, casePrices);
              }
            }

            // Method 3: Fallback - largest price, but only if > $5
            // Prices under $5 are almost always per-unit prices
            if (!price) {
              var priceMatches = text.match(/\\$(\\d+[,\\d]*\\.\\d{2})/g) || [];
              var allPrices = priceMatches.map(function(p) {
                return parseFloat(p.replace('$', '').replace(',', ''));
              });
              if (allPrices.length > 0) {
                var maxPrice = Math.max.apply(null, allPrices);
                if (maxPrice > 5) price = maxPrice;
              }
            }

            return {
              sku: skuMatch[1],
              name: brand ? (brand + ' ' + desc) : desc,
              price: price,
              pack_size: packEl ? packEl.innerText.trim() : '',
              in_stock: !text.toLowerCase().includes('out of stock')
            };
          })()
        JS
      rescue StandardError
        nil
      end

      return nil unless product_data

      {
        supplier_sku: product_data['sku'],
        supplier_name: product_data['name'],
        current_price: product_data['price'],
        pack_size: product_data['pack_size'],
        in_stock: product_data['in_stock'] != false,
        scraped_at: Time.current
      }
    end

    def check_order_minimum_at_checkout
      subtotal_text = extract_text(".cart-subtotal, .subtotal, [data-testid='subtotal']")
      current_total = extract_price(subtotal_text) || 0

      minimum_text = extract_text('.order-minimum-message, .minimum-order')
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
        next unless item.at_css('.out-of-stock, .unavailable, .item-unavailable')

        unavailable << {
          sku: item.at_css('[data-sku]')&.attribute('data-sku'),
          name: item.at_css('.item-name, .product-name')&.text&.strip,
          message: item.at_css('.availability-message')&.text&.strip
        }
      end

      unavailable
    end

    def detect_price_changes_in_cart
      changes = []

      browser.css('.cart-item, .line-item').each do |item|
        price_warning = item.at_css('.price-changed-warning, .price-alert')
        next unless price_warning

        changes << {
          sku: item.at_css('[data-sku]')&.attribute('data-sku'),
          name: item.at_css('.item-name, .product-name')&.text&.strip,
          old_price: extract_price(item.at_css('.original-price, .was-price')&.text),
          new_price: extract_price(item.at_css('.current-price, .now-price')&.text)
        }
      end

      changes
    end

    def validate_cart_before_checkout
      detect_error_conditions

      return unless browser.at_css('.empty-cart, .cart-empty')

      raise ScrapingError, 'Cart is empty'
    end

    def delivery_date_available?
      browser.at_css('.delivery-date-selector option:not([disabled]), .delivery-slot:not(.unavailable)').present?
    end

    def wait_for_confirmation_or_error
      start_time = Time.current
      timeout = 30

      loop do
        return true if browser.at_css(".order-confirmation, .confirmation-page, [data-testid='confirmation']")

        error_msg = browser.at_css('.checkout-error, .order-error, .alert-danger')&.text&.strip
        handle_checkout_error(error_msg) if error_msg

        raise ScrapingError, 'Checkout timeout' if Time.current - start_time > timeout

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
      hold_banner = browser.at_css('.account-hold-banner, .account-alert')
      raise AccountHoldError, hold_banner.text.strip if hold_banner

      credit_warning = browser.at_css('.credit-limit-warning, .credit-alert')
      return unless credit_warning

      raise AccountHoldError, "Credit limit reached: #{credit_warning.text.strip}"
    end
  end
end
