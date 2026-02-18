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

      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'

      browser_opts = {
        headless: headless_mode ? 'new' : false,
        timeout: 90,
        process_timeout: 60,
        window_size: [1280, 720],
        browser_options: {
          "no-sandbox": true,
          "disable-gpu": true,
          "disable-dev-shm-usage": true,
          "disable-blink-features": 'AutomationControlled',
          "user-agent": ua,
          # Stealth flags
          "disable-features": 'AutomationControlled,TranslateUI',
          "excludeSwitches": 'enable-automation',
          # Prevent Chromium from restoring previous tabs or opening default pages
          "no-first-run": true,
          "no-default-browser-check": true,
          "disable-component-update": true,
          "disable-session-crashed-bubble": true,
          # Memory optimization for Railway 1GB container
          "disable-extensions": true,
          "disable-default-apps": true,
          "disable-translate": true,
          "disable-sync": true,
          "disable-background-timer-throttling": true,
          "disable-renderer-backgrounding": true,
          "disable-backgrounding-occluded-windows": true,
          "js-flags": '--max-old-space-size=256 --lite-mode',
          "renderer-process-limit": 1,
          "disable-software-rasterizer": true,
          "disable-image-loading": false
        }
      }

      browser_opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?

      @browser = Ferrum::Browser.new(**browser_opts)

      # Block images, fonts, and analytics to reduce memory usage on Railway.
      # The scraper only needs HTML/CSS/JS — not product images or tracking pixels.
      begin
        browser.network.intercept
        browser.on(:request) do |request|
          url = request.url
          if url.match?(/\.(jpg|jpeg|png|gif|webp|svg|ico|woff|woff2|ttf|eot)(\?|$)/i) ||
             url.include?('adobedtm.com') ||
             url.include?('analytics') ||
             url.include?('google-analytics') ||
             url.include?('googletagmanager')
            request.abort
          else
            request.continue
          end
        end
      rescue StandardError => e
        logger.warn "[UsFoods] Network interception setup failed: #{e.message}"
      end

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
        browser.evaluate_on_new_document(stealth_js)
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
        begin
          browser.goto(BASE_URL)
        rescue Ferrum::PendingConnectionsError
          # Expected for US Foods SPA
        end
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

    # US Foods catalog import — hybrid strategy (2025 site redesign):
    #
    # FAST (scrape_catalog): Empty search (searchText=) returns ~2,000 products
    # available to this customer in ~8.5 minutes. Used for regular imports.
    #
    # DEEP (scrape_catalog_deep): Browses all 11 food categories and their
    # subcategories for comprehensive coverage. Takes 1-3 hours but finds
    # tens of thousands of products. Run as a separate daily background job.

    # Top-level food categories on the US Foods browse page.
    # Excludes non-food categories (Equipment & Supplies, Disposables,
    # Chemicals & Cleaning) to keep import focused on food products.
    FOOD_CATEGORIES = %w[
      beef
      beverages
      dairy-and-eggs
      dry-storage
      fresh-produce
      frozen-foods
      pork
      poultry
      prepared-foods-and-deli
      seafood
      specialty-meats
    ].freeze

    # Fast catalog import: empty search returns the customer's available products.
    # Gets ~2,000 products in ~8.5 minutes — good enough for regular imports.
    def scrape_catalog(_search_terms, max_per_term: 100, &on_batch)
      results = []
      total_yielded = 0

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

        # Use empty search to get the full "available to this customer" catalog
        import_start = Time.current
        products = search_and_scroll_all('')
        logger.info "[UsFoods] Empty search returned #{products.size} products"

        if on_batch && products.any?
          on_batch.call(products)
          total_yielded += products.size
        else
          results.concat(products)
        end

        elapsed_min = ((Time.current - import_start) / 60).round(1)
        total_count = on_batch ? total_yielded : results.size
        logger.info "[UsFoods] Fast catalog import complete: #{total_count} products in #{elapsed_min} min"

        # Refresh session at end of successful scrape
        save_session if total_count > 0
      end

      # When using block mode, the service handles dedup — return empty
      return [] if on_batch

      # Legacy mode: de-duplicate by SKU and return array
      deduped = results.uniq { |r| r[:supplier_sku] }
      logger.info "[UsFoods] Total unique products: #{deduped.size} (from #{results.size} raw)"
      deduped
    end

    # Deep catalog import: browse all food categories and subcategories.
    # This finds products the empty search misses (tens of thousands total).
    # Takes 1-3 hours — designed to run as a daily background job.
    def scrape_catalog_deep(&on_batch)
      total_yielded = 0

      with_browser do
        session_restored = false
        if restore_session
          browser.refresh
          sleep 3
          if logged_in?
            logger.info '[UsFoods] Session restored for deep import'
            session_restored = true
          end
        end

        unless session_restored
          perform_login_steps
          sleep 3
          raise AuthenticationError, 'Could not log in for deep catalog import' unless logged_in?
        end

        save_session

        import_start = Time.current
        FOOD_CATEGORIES.each do |category|
          subcategories = discover_subcategories(category)
          display_name = category.gsub('-', ' ').split.map(&:capitalize).join(' ')

          if subcategories.any?
            logger.info "[UsFoods] #{display_name}: #{subcategories.size} subcategories"
            subcategories.each do |subcat|
              path = "/desktop/search2/product-listing/#{category}/#{subcat[:slug]}"
              products = browse_category_page(path)
              products.each { |p| p[:category] ||= display_name }

              if on_batch
                on_batch.call(products)
                total_yielded += products.size
              end

              logger.info "[UsFoods] #{display_name}/#{subcat[:name]}: #{products.size} products (total: #{total_yielded})"
            rescue StandardError => e
              logger.warn "[UsFoods] Failed #{display_name}/#{subcat[:name]}: #{e.class}: #{e.message}"
            end
          else
            # No subcategories found — browse the top-level category directly
            begin
              path = "/desktop/search2/product-listing/#{category}"
              products = browse_category_page(path)
              products.each { |p| p[:category] ||= display_name }

              if on_batch
                on_batch.call(products)
                total_yielded += products.size
              end

              logger.info "[UsFoods] #{display_name}: #{products.size} products (total: #{total_yielded})"
            rescue StandardError => e
              logger.warn "[UsFoods] Failed #{display_name}: #{e.class}: #{e.message}"
            end
          end

          # Save session periodically to keep it alive during long import
          save_session
        end

        elapsed_min = ((Time.current - import_start) / 60).round(1)
        logger.info "[UsFoods] Deep category browsing complete: #{total_yielded} products in #{elapsed_min} min"
      end

      total_yielded
    end

    # Discover subcategories for a top-level category by visiting its landing page.
    # Returns an array of { name:, slug: } hashes.
    def discover_subcategories(category)
      navigate_to("#{BASE_URL}/desktop/category-landing/#{category}")
      sleep 5 # Wait for Angular SPA to render the subcategory tiles

      subcats_json = browser.evaluate(<<~JS)
        (function() {
          var result = [];
          // Subcategory tiles use .image-bubble-text class
          var bubbles = document.querySelectorAll('.image-bubble-text, [class*=image-bubble] p');
          for (var i = 0; i < bubbles.length; i++) {
            var text = (bubbles[i].innerText || '').trim();
            if (text.length > 1 && text.length < 80) result.push(text);
          }
          // Fallback: ion-card elements with short text
          if (result.length === 0) {
            var cards = document.querySelectorAll('ion-card');
            for (var i = 0; i < cards.length; i++) {
              var text = (cards[i].innerText || '').trim();
              if (text.length > 1 && text.length < 80 && !text.match(/^#/) && !text.match(/^\\$/) && text !== 'Shop All Products') {
                result.push(text);
              }
            }
          }
          return JSON.stringify(result);
        })()
      JS

      subcats = JSON.parse(subcats_json)
      subcats.map do |name|
        slug = name.downcase.gsub(/[^a-z0-9\s]/, '').strip.gsub(/\s+/, '-')
        { name: name, slug: slug }
      end
    rescue StandardError => e
      logger.warn "[UsFoods] Failed to discover subcategories for #{category}: #{e.message}"
      []
    end

    # Browse a category/subcategory product listing page and scroll through
    # the CDK virtual scroll to extract all products.
    def browse_category_page(path)
      navigate_to("#{BASE_URL}#{path}")
      sleep 4

      card_count = begin
        browser.evaluate("document.querySelectorAll('.product-wrapper').length")
      rescue StandardError
        0
      end
      if card_count == 0
        sleep 3
        card_count = begin
          browser.evaluate("document.querySelectorAll('.product-wrapper').length")
        rescue StandardError
          0
        end
        return [] if card_count == 0
      end

      # Scroll through CDK virtual scroll, extracting products as we go
      all_products = {}
      stale_rounds = 0

      200.times do |_attempt|
        page_products = extract_products_from_page
        new_count = 0
        page_products.each do |p|
          next if p[:supplier_sku].blank?

          unless all_products.key?(p[:supplier_sku])
            all_products[p[:supplier_sku]] = p
            new_count += 1
          end
        end

        if new_count == 0
          stale_rounds += 1
          break if stale_rounds >= 4
        else
          stale_rounds = 0
        end

        scroll_virtual_list
        sleep 1.5
      end

      all_products.values
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

    # Override navigate_to for US Foods — the Ionic SPA makes continuous
    # background API calls (analytics, product prefetch, images) that
    # prevent Ferrum's default network-idle detection from ever resolving.
    # Rescue the PendingConnectionsError since the page is usable even
    # with background requests still in flight.
    def navigate_to(url)
      logger.debug "[UsFoods] Navigating to: #{url}"
      browser.goto(url)
      sleep 1
    rescue Ferrum::PendingConnectionsError => e
      logger.debug "[UsFoods] Pending connections (expected for SPA): #{e.message.truncate(200)}"
      sleep 1
    end

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

    # Search for a term and scroll through ALL results, extracting products as we go.
    #
    # US Foods uses Angular CDK virtual scroll — only ~12-25 product cards are in
    # the DOM at any time. As you scroll, previous cards are removed and new ones
    # are rendered. We must extract products from each "window" as we scroll,
    # accumulating them since they'll be recycled out of the DOM.
    #
    # Returns an array of product hashes (already deduped by SKU).
    def search_and_scroll_all(term)
      logger.info "[UsFoods] Searching for: #{term}"

      search_url = "#{BASE_URL}/desktop/search?searchText=#{CGI.escape(term)}"
      navigate_to(search_url)
      sleep 4

      # Check if products loaded — .product-wrapper contains the full product info
      card_count = begin
        browser.evaluate("document.querySelectorAll('.product-wrapper').length")
      rescue StandardError
        0
      end
      if card_count == 0
        page_text = begin
          browser.evaluate('document.body?.innerText?.substring(0, 500)')
        rescue StandardError
          ''
        end
        if page_text.include?("couldn't find any matches") || page_text.include?('0 Results')
          logger.info "[UsFoods] No results for '#{term}'"
          return []
        end
        # Wait a bit more for SPA rendering
        sleep 3
        card_count = begin
          browser.evaluate("document.querySelectorAll('.product-wrapper').length")
        rescue StandardError
          0
        end
        if card_count == 0
          logger.warn "[UsFoods] No product-wrappers found for '#{term}'"
          return []
        end
      end

      logger.info "[UsFoods] '#{term}': #{card_count} cards on initial load"

      # Extract products while scrolling through the virtual scroll viewport.
      # Each scroll renders a new window of ~12-25 cards; previous ones are removed.
      all_products = {}  # SKU => product hash (dedup as we go)
      stale_rounds = 0
      max_scrolls = 200  # Safety cap

      max_scrolls.times do |attempt|
        # Extract whatever is currently visible
        page_products = extract_products_from_page
        new_count = 0
        page_products.each do |p|
          next if p[:supplier_sku].blank?

          unless all_products.key?(p[:supplier_sku])
            all_products[p[:supplier_sku]] = p
            new_count += 1
          end
        end

        if new_count == 0
          stale_rounds += 1
          break if stale_rounds >= 4 # No new products after 4 consecutive scrolls
        else
          stale_rounds = 0
        end

        if (attempt + 1) % 10 == 0 || new_count > 0
          logger.info "[UsFoods] '#{term}' scroll #{attempt + 1}: +#{new_count} new (#{all_products.size} total unique)"
        end

        # Scroll the CDK virtual scroll container
        scroll_virtual_list
        sleep 1.5
      end

      logger.info "[UsFoods] '#{term}': #{all_products.size} unique products after scrolling"
      all_products.values
    end

    # Scroll the Angular CDK virtual scroll viewport that US Foods uses.
    # This is the actual scrollable container — window.scrollTo does nothing.
    def scroll_virtual_list
      browser.evaluate(<<~JS)
        (function() {
          // Primary: Angular CDK virtual scroll viewport
          var vScroll = document.querySelector('.cdk-virtual-scrollable');
          if (vScroll) {
            vScroll.scrollTop = vScroll.scrollHeight;
            return;
          }

          // Fallback: any element with cdk-virtual-scroll in class
          var cdkEl = document.querySelector('[class*="cdk-virtual-scroll"]');
          if (cdkEl) {
            cdkEl.scrollTop = cdkEl.scrollHeight;
            return;
          }

          // Last resort: window scroll
          window.scrollTo(0, document.body.scrollHeight);
        })()
      JS
    rescue StandardError => e
      logger.debug "[UsFoods] scroll_virtual_list error: #{e.message}"
      nil
    end

    # Extract product data from all .product-card elements on the page.
    #
    # US Foods product card innerText structure:
    #   Patuxent Farms                   (brand)
    #   Chicken, Thigh Meat Jumbo...     (description)
    #   #2723278                         (SKU)
    #   4/10 LB                          (pack size)
    #   ($1.62 / LB)                     (unit price)
    #   4.1                              (rating)
    #   Recent Purchase                  (tags)
    #   $64.62 CS                        (case price)
    def extract_products_from_page
      products_json = begin
        browser.evaluate(<<~JS)
          (function() {
            var cards = document.querySelectorAll('.product-wrapper');
            var products = [];
            var seen = {};

            for (var i = 0; i < cards.length; i++) {
              var card = cards[i];
              var text = card.innerText || '';
              var lines = text.split('\\n').map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });

              // Find SKU line (#NNNNNNN)
              var sku = null;
              var skuLineIdx = -1;
              for (var j = 0; j < lines.length; j++) {
                var m = lines[j].match(/^#(\\d{5,})$/);
                if (m) { sku = m[1]; skuLineIdx = j; break; }
              }
              // Fallback: SKU anywhere in text
              if (!sku) {
                var sm = text.match(/#(\\d{5,})/);
                if (sm) sku = sm[1];
              }
              if (!sku || seen[sku]) continue;
              seen[sku] = true;

              // Brand is typically 2 lines before SKU, description 1 line before
              var brand = (skuLineIdx >= 2) ? lines[skuLineIdx - 2] : '';
              var description = (skuLineIdx >= 1) ? lines[skuLineIdx - 1] : '';

              // Skip non-brand lines that leaked in
              if (brand.match(/^(\\$|Order today|Recent|On My|Locally|Compare|Add|All Filters|Category)/i)) brand = '';

              var name = brand ? (brand + ' ' + description) : description;
              if (!name || name.trim().length < 3) continue;

              // Pack size is typically 1 line after SKU
              var packSize = (skuLineIdx >= 0 && skuLineIdx + 1 < lines.length) ? lines[skuLineIdx + 1] : '';
              // Validate it looks like a pack size
              if (!packSize.match(/\\d/)) packSize = '';

              // Case price: find "$XX.XX CS" pattern
              var price = null;
              var csMatch = text.match(/\\$(\\d+[,\\d]*\\.\\d{2})\\s*CS/i);
              if (csMatch) {
                price = parseFloat(csMatch[1].replace(',', ''));
              }

              // Fallback: largest non-unit price
              if (!price) {
                var priceRegex = /\\$(\\d+[,\\d]*\\.\\d{2})(?!\\s*\\/|\\s*CS)/g;
                var pm;
                var prices = [];
                while ((pm = priceRegex.exec(text)) !== null) {
                  prices.push(parseFloat(pm[1].replace(',', '')));
                }
                if (prices.length > 0) price = Math.max.apply(null, prices);
              }

              var inStock = !text.toLowerCase().includes('out of stock') &&
                            !text.toLowerCase().includes('unavailable');

              products.push({
                sku: sku,
                brand: brand,
                name: name.substring(0, 255),
                pack_size: packSize,
                price: price,
                in_stock: inStock
              });
            }

            return JSON.stringify(products);
          })()
        JS
      rescue StandardError => e
        logger.warn "[UsFoods] extract_products_from_page error: #{e.message}"
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

            // Try data-cy selectors (old layout) first, then fall back to text parsing
            var brandEl = document.querySelector('[data-cy*="product-brand"]');
            var descEl = document.querySelector('[data-cy="product-description-text"]');
            var packEl = document.querySelector('[data-cy*="product-packsize"]');

            var brand = brandEl ? brandEl.innerText.trim() : '';
            var desc = descEl ? descEl.innerText.trim() : '';
            var packSize = packEl ? packEl.innerText.trim() : '';

            // If data-cy elements not found, parse from text (new layout)
            if (!desc) {
              var lines = text.split('\\n').map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });
              for (var i = 0; i < lines.length; i++) {
                if (lines[i].includes('#' + skuMatch[1])) {
                  if (i >= 1) desc = lines[i - 1];
                  if (i >= 2 && lines[i - 2].length < 80) brand = lines[i - 2];
                  // Extract pack size from SKU line
                  var pm = lines[i].match(/#\\d+\\s+(.+?)\\s*\\(/);
                  if (pm && !packSize) packSize = pm[1].trim();
                  break;
                }
              }
            }

            // Extract CASE PRICE — prefer "$XX.XX CS" format (new layout)
            var price = null;

            // Method 1: "$XX.XX CS" pattern
            var csMatch = text.match(/\\$(\\d+[,\\d]*\\.\\d{2})\\s*CS/i);
            if (csMatch) {
              price = parseFloat(csMatch[1].replace(',', ''));
            }

            // Method 2: data-cy case price element (old layout)
            if (!price) {
              var casePriceEl = document.querySelector('[data-cy*="case-price"], [data-cy*="product-price"]:not([data-cy*="unit"])');
              if (casePriceEl) {
                var cpm = casePriceEl.innerText.match(/\\$(\\d+[,\\d]*\\.\\d{2})/);
                if (cpm) price = parseFloat(cpm[1].replace(',', ''));
              }
            }

            // Method 3: Find prices excluding unit prices (with /unit suffix)
            if (!price) {
              var priceRegex = /\\$(\\d+[,\\d]*\\.\\d{2})(\\/[a-zA-Z]+)?/g;
              var match;
              var casePrices = [];
              while ((match = priceRegex.exec(text)) !== null) {
                if (!match[2]) casePrices.push(parseFloat(match[1].replace(',', '')));
              }
              if (casePrices.length > 0) price = Math.max.apply(null, casePrices);
            }

            return {
              sku: skuMatch[1],
              name: brand ? (brand + ' ' + desc) : desc,
              price: price,
              pack_size: packSize,
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
