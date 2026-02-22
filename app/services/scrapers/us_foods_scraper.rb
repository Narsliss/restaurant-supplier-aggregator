module Scrapers
  class UsFoodsScraper < BaseScraper
    BASE_URL = 'https://order.usfoods.com'.freeze
    ORDER_MINIMUM = 250.00
    CHECKOUT_LIVE = false # HARD SAFETY GATE: set to true ONLY when ready for live US Foods orders

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

    # Keep a single browser alive across clear_cart → add_to_cart → checkout.
    # US Foods uses an order-based model — the active order context may not
    # survive across separate browser sessions. Reusing one browser avoids
    # losing the order between steps.
    def ensure_order_browser!
      return if @browser # Already have an open browser

      ua = if ENV['BROWSER_PATH'].present? || Rails.env.production?
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
          "disable-features": 'AutomationControlled,TranslateUI',
          "excludeSwitches": 'enable-automation',
          "no-first-run": true,
          "no-default-browser-check": true,
          "disable-component-update": true,
          "disable-session-crashed-bubble": true,
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

      logger.info '[UsFoods] Starting order browser (persistent for checkout flow)'
      @browser = Ferrum::Browser.new(**browser_opts)

      # Network interception (block images/analytics)
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
        logger.warn "[UsFoods] Order browser network interception failed: #{e.message}"
      end

      # Inject stealth scripts via CDP
      begin
        stealth_js = <<~JS
          Object.defineProperty(navigator, 'webdriver', {get: () => false});
          Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
          Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
          if (!window.chrome) window.chrome = {};
          if (!window.chrome.runtime) window.chrome.runtime = {};
        JS
        browser.evaluate_on_new_document(stealth_js)
      rescue StandardError => e
        logger.warn "[UsFoods] Order browser CDP stealth failed: #{e.message}"
      end

      # Login
      if restore_session
        navigate_to(BASE_URL)
        sleep 2
        unless logged_in?
          logger.info '[UsFoods] Order browser session invalid, performing fresh login'
          perform_login_steps
          save_session
        end
      else
        logger.info '[UsFoods] Order browser no session, performing login'
        perform_login_steps
        save_session
      end

      logger.info '[UsFoods] Order browser ready'
    end

    def close_order_browser!
      save_session if @browser
      @browser&.quit
      @browser = nil
    rescue StandardError => e
      logger.debug "[UsFoods] Error closing order browser: #{e.message}"
      @browser = nil
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
        # Restore session inline — do NOT call login() which has its own
        # with_browser block and would create a nested browser (killing ours).
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          sleep 2
        end
        unless logged_in?
          perform_login_steps
          sleep 3
          raise AuthenticationError, 'Could not log in for price verification' unless logged_in?
        end
        save_session

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

    # Scrape saved order lists from US Foods /desktop/lists page.
    # US Foods organizes lists with names and product counts.
    # Returns array of list hashes per the BaseScraper#scrape_lists contract.
    def scrape_supplier_lists
      lists_url = "#{BASE_URL}/desktop/lists"
      logger.info "[UsFoods] Navigating to lists page: #{lists_url}"
      navigate_to(lists_url)
      sleep 5

      # US Foods uses Angular/Ionic with data-cy attributes for testing.
      # The lists page has multiple sections (app-sortable-section-desktop-tablet),
      # each containing ion-row elements with data-cy="list-data-row-{index}".
      # List rows are NOT links — clicking a row navigates via Angular router
      # to /desktop/lists/view/SL-{id}. The SL-{id} is only in the resulting URL.
      #
      # Sections: "Last Viewed" (often empty), "My Shopping Lists", "Managed By US Foods"
      # Row indices reset within each section.

      # Extract section names and their list rows from the DOM
      lists_metadata = browser.evaluate(<<~JS)
        (function() {
          var sections = document.querySelectorAll('app-sortable-section-desktop-tablet');
          var allLists = [];
          var globalIndex = 0;

          for (var s = 0; s < sections.length; s++) {
            var titleEl = sections[s].querySelector('[data-cy=sortable-section-title-text]');
            var sectionName = titleEl ? titleEl.innerText.trim() : 'Unknown';

            // Skip the "Last Viewed" section — it's ephemeral and usually empty
            if (sectionName === 'Last Viewed') continue;

            var rows = sections[s].querySelectorAll('ion-row[data-cy^="list-data-row-"]');
            for (var r = 0; r < rows.length; r++) {
              var nameEl = rows[r].querySelector('p[data-cy^="list-data-list-name-text-"]');
              var productsEl = rows[r].querySelector('div[data-cy^="list-data-products-icon-"]');

              var name = nameEl ? nameEl.innerText.trim() : '';
              var productCount = productsEl ? parseInt(productsEl.innerText.trim()) || 0 : 0;

              if (name.length > 0) {
                allLists.push({
                  name: name,
                  section: sectionName,
                  section_index: s,
                  row_index: r,
                  global_index: globalIndex,
                  product_count: productCount
                });
                globalIndex++;
              }
            }
          }

          return JSON.stringify(allLists);
        })()
      JS

      parsed_lists = begin
        JSON.parse(lists_metadata)
      rescue StandardError
        []
      end

      logger.info "[UsFoods] Found #{parsed_lists.size} lists on lists page"

      if parsed_lists.empty?
        logger.info '[UsFoods] No lists found on page'
        return []
      end

      # Scrape products from each list by clicking into it
      result_lists = []
      parsed_lists.each_with_index do |list_data, idx|
        list_name = list_data['name']
        section = list_data['section']
        row_index = list_data['row_index']
        section_index = list_data['section_index']
        product_count = list_data['product_count']

        logger.info "[UsFoods] Scraping list '#{list_name}' (section: #{section}, #{product_count} products expected)"

        # Navigate back to lists index if not already there (skip on first iteration)
        if idx > 0
          navigate_to(lists_url)
          sleep 4
        end

        # Click the list row to navigate to its detail page.
        # Since row indices reset per section, we target by section index then row index.
        clicked = browser.evaluate(<<~JS)
          (function() {
            var sections = document.querySelectorAll('app-sortable-section-desktop-tablet');
            if (sections.length <= #{section_index}) return 'section_not_found';

            var rows = sections[#{section_index}].querySelectorAll('ion-row[data-cy^="list-data-row-"]');
            if (rows.length <= #{row_index}) return 'row_not_found';

            var nameCol = rows[#{row_index}].querySelector('ion-col[data-cy^="list-data-list-name-column-"]');
            if (nameCol) {
              nameCol.click();
              return 'clicked';
            }
            return 'name_col_not_found';
          })()
        JS

        unless clicked == 'clicked'
          logger.warn "[UsFoods] Could not click list '#{list_name}': #{clicked}"
          next
        end

        sleep 5

        # Extract the list ID from the resulting URL.
        # Patterns: /lists/view/SL-7115892, /lists/view/OG-795581, /lists/recentlyPurchased
        current_url = browser.current_url
        remote_id = current_url[%r{/lists/view/([A-Z]+-\d+)}, 1] ||
                    current_url[%r{/lists/([^/?]+)$}, 1]

        unless remote_id
          logger.warn "[UsFoods] Could not extract list ID from URL: #{current_url}"
          remote_id = list_name.downcase.gsub(/[^a-z0-9]+/, '-')
        end

        logger.info "[UsFoods] List '#{list_name}' has ID #{remote_id} (URL: #{current_url})"

        # Determine list type
        list_type = if section == 'Managed By US Foods'
                      list_name.match?(/order\s*guide/i) ? 'order_guide' : 'managed'
                    else
                      'custom'
                    end

        products = scroll_and_extract_list_products
        logger.info "[UsFoods] List '#{list_name}': #{products.size} products scraped"

        result_lists << {
          name: list_name,
          remote_id: remote_id,
          url: current_url,
          list_type: list_type,
          items: products
        }

        rate_limit_delay
      end

      result_lists
    end

    # Scroll through a list page and extract all products using the same
    # virtual scroll + product extraction logic used for catalog scraping.
    def scroll_and_extract_list_products
      # Wait for products to render
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

      all_products = {}
      stale_rounds = 0
      max_scrolls = 200

      max_scrolls.times do |_attempt|
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

      # Convert to list item format
      position = 0
      all_products.values.map do |p|
        position += 1
        {
          sku: p[:supplier_sku],
          name: p[:supplier_name],
          price: p[:current_price],
          pack_size: p[:pack_size],
          quantity: 1,
          in_stock: p[:in_stock] != false,
          position: position
        }
      end
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

      # Use persistent order browser — keeps same browser across
      # clear_cart → add_to_cart → checkout so the active order is preserved.
      ensure_order_browser!

      logger.info "[UsFoods] Logged in, starting add-to-cart for #{items.size} items"
      logger.info "[UsFoods] Target delivery date: #{@target_delivery_date || 'default'}"

      # Step 0: Ensure an active order exists on the site.
      # US Foods requires creating an order (with delivery date) before items
      # can be added. Without an active order, quantity inputs on search pages
      # don't register and items won't be added to any order.
      ensure_active_order_on_site!

      added_items = []
      failed_items = []

      items.each do |item|
        begin
          add_item_to_order(item[:sku], item[:quantity])
          added_items << item
          logger.info "[UsFoods] Added SKU #{item[:sku]} qty #{item[:quantity]} to order"
        rescue ItemUnavailableError => e
          # Item is genuinely out of stock on US Foods — skip it but report it properly
          # so handle_skipped_cart_items can mark the supplier_product as OOS.
          oos_name = e.items&.first&.dig(:name) || "SKU #{item[:sku]}"
          logger.warn "[UsFoods] SKU #{item[:sku]} is out of stock — skipping: #{e.message}"
          failed_items << { sku: item[:sku], name: oos_name, error: e.message, out_of_stock: true }
        rescue StandardError => e
          logger.warn "[UsFoods] Failed to add SKU #{item[:sku]}: #{e.message}"
          failed_items << { sku: item[:sku], name: "SKU #{item[:sku]}", error: e.message }
        end
        rate_limit_delay
      end

      # Bulk verify: navigate to order page ONCE and check all SKUs.
      # This avoids navigating away between adds (which can interrupt async adds).
      if added_items.any?
        expected_skus = added_items.map { |i| i[:sku].to_s }
        verification = verify_items_on_order_page(expected_skus)

        # Any items not found on the order page are actually failed
        if verification[:missing].any?
          verification[:missing].each do |sku|
            item = added_items.find { |i| i[:sku].to_s == sku.to_s }
            added_items.delete(item) if item
            failed_items << { sku: sku, name: "SKU #{sku}", error: 'Not found on order page after add' }
            logger.warn "[UsFoods] SKU #{sku} was NOT on the order page — add likely failed"
          end
        end
      end

      if failed_items.any? && added_items.empty?
        close_order_browser!

        # If ALL items failed because they're OOS, raise ItemUnavailableError
        # (this correctly triggers stock-marking behavior).
        # If items failed for OTHER reasons (scraper bugs), raise ScrapingError
        # to avoid falsely marking products as out of stock.
        all_oos = failed_items.all? { |f| f[:out_of_stock] }
        if all_oos
          raise ItemUnavailableError.new(
            "All #{failed_items.size} items are out of stock on US Foods",
            items: failed_items.map { |f| { sku: f[:sku], name: f[:name], message: f[:error] } }
          )
        else
          raise ScrapingError, "Failed to add any items to US Foods order. " \
            "SKUs: #{failed_items.map { |f| f[:sku] }.join(', ')}. " \
            "Errors: #{failed_items.map { |f| f[:error] }.first(3).join('; ')}"
        end
      end

      logger.info "[UsFoods] Added #{added_items.size} items to order (#{failed_items.size} failed)"
      { added: added_items.size, failed: failed_items }
    end

    # Ensure there's an active order on the US Foods site.
    # Without an active order, setting quantities on search pages won't add
    # items to an order. We must create one from the order page first.
    def ensure_active_order_on_site!
      navigate_to("#{BASE_URL}/desktop/order")
      sleep 2

      # Check current page state — look at buttons to determine order status
      page_state = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('ion-button, button');
          var visible = Array.from(buttons).filter(function(b) { return b.offsetParent !== null; });
          var texts = visible.map(function(b) { return (b.innerText || '').trim().toLowerCase(); });

          var hasCancel = texts.some(function(t) { return t.includes('cancel order'); });
          var hasAddProducts = texts.some(function(t) { return t === 'add products'; });
          var hasStartOrder = texts.some(function(t) { return t.includes('start an order'); });
          var hasCreateOrder = texts.some(function(t) { return t.includes('create order'); });

          // Check for items in the order — look for product rows or price
          var pageText = document.body ? document.body.innerText : '';
          var hasTotal = !!pageText.match(/Total:\\s*\\$[1-9]/); // Non-zero total = real order with items

          // Look for Cart button with items: "Cart: $X.XX (N)"
          var cartButton = null;
          for (var btn of visible) {
            var text = (btn.innerText || '').trim();
            var match = text.match(/Cart:\\s*\\$(\S+)\\s*\\((\d+)\\)/);
            if (match) {
              cartButton = { total: match[1], count: parseInt(match[2]), text: text };
              break;
            }
          }

          return {
            has_cancel: hasCancel,
            has_add_products: hasAddProducts,
            has_start_order: hasStartOrder,
            has_create_order: hasCreateOrder,
            has_nonzero_total: hasTotal,
            cart_button: cartButton,
            buttons: texts.filter(function(t) { return t.length > 0; }).slice(0, 15)
          };
        })()
      JS
      logger.info "[UsFoods] Order page state: #{page_state}"

      # Determine if a real, active order already exists.
      # A real order has EITHER:
      #   - A non-zero total (items already on it)
      #   - A Cart button showing items
      #   - "Add Products" visible WITHOUT "Start An Order"
      # If "Start An Order" is visible, it means the order page is empty and
      # no deliverable order has been created yet.
      has_real_order = page_state &&
        !page_state['has_start_order'] &&
        (page_state['has_add_products'] || page_state['has_nonzero_total'] || page_state['cart_button'])

      if has_real_order
        logger.info '[UsFoods] Active order already exists — no creation needed'
        return
      end

      # No active order. We need to click "Create Order" (the next-delivery-button
      # in the header) — NOT "Start An Order" which just navigates to the lists page.
      #
      # "Create Order" with class `next-delivery-button` creates an order for the
      # next available delivery date. "Start An Order" misleadingly just goes to
      # /desktop/lists to browse products — it does NOT create an order.
      logger.info '[UsFoods] No active order — clicking "Create Order" to create one'

      create_result = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('ion-button, button');

          // PRIORITY: Click "Create Order" (the next-delivery-button in header).
          // This is the REAL order creation button that sets up a delivery date.
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            var text = (btn.innerText || '').trim().toLowerCase();
            if (text.includes('create order')) {
              btn.scrollIntoView({ behavior: 'instant', block: 'center' });
              btn.click();
              return { clicked: true, text: btn.innerText.trim(), method: 'create-order' };
            }
          }

          return { clicked: false };
        })()
      JS

      if create_result && create_result['clicked']
        logger.info "[UsFoods] Clicked '#{create_result['text']}' — waiting for order creation"
        sleep 3

        # After clicking "Create Order", a delivery date selection modal may appear,
        # or the order may be created directly with the next available date.
        complete_order_creation_flow
      else
        logger.warn "[UsFoods] Could not find 'Create Order' button. Buttons: #{page_state&.dig('buttons')}"
      end
    end

    # Complete the order creation flow after "Create Order" was clicked.
    # This handles any delivery date selection modal, delivery type options
    # (Pronto/Regular), and confirmation buttons.
    def complete_order_creation_flow
      # Log the page state to see what appeared after clicking "Create Order"
      page_snapshot = browser.evaluate(<<~JS)
        (function() {
          var body = document.body ? document.body.innerText : '';

          // All visible buttons
          var buttons = Array.from(document.querySelectorAll('ion-button, button, [role="button"]'))
            .filter(function(b) { return b.offsetParent !== null; })
            .map(function(b) {
              return {
                text: (b.innerText || '').trim().substring(0, 80),
                tag: b.tagName,
                class: (b.className || '').substring(0, 100)
              };
            })
            .filter(function(b) { return b.text.length > 0; });

          // All visible clickable elements that might be date tiles or delivery options
          var clickables = Array.from(document.querySelectorAll(
            'ion-card, ion-item, ion-chip, ion-segment-button, [class*="date"], ' +
            '[class*="delivery"], [class*="tile"], [class*="option"], [class*="select"], ' +
            '[class*="calendar"], [class*="schedule"]'
          ))
            .filter(function(el) { return el.offsetParent !== null; })
            .slice(0, 20)
            .map(function(el) {
              return {
                tag: el.tagName,
                text: (el.innerText || '').trim().substring(0, 100),
                class: (el.className || '').substring(0, 100)
              };
            });

          // Any modals/overlays/alerts that appeared
          var modals = Array.from(document.querySelectorAll(
            'ion-modal, ion-alert, ion-popover, ion-action-sheet, ' +
            '[class*="modal"], [class*="overlay"], [role="dialog"], [role="alertdialog"]'
          )).filter(function(m) {
            return m.offsetParent !== null || m.classList.contains('show') ||
                   getComputedStyle(m).display !== 'none';
          }).map(function(m) {
            return {
              tag: m.tagName,
              text: (m.innerText || '').trim().substring(0, 400)
            };
          });

          return {
            page_text: body.substring(0, 800),
            url: location.href,
            buttons: buttons.slice(0, 20),
            clickables: clickables,
            modals: modals.filter(function(m) { return m.text.length > 0; })
          };
        })()
      JS
      logger.info "[UsFoods] Post-'Create Order' page state:"
      logger.info "[UsFoods]   URL: #{page_snapshot['url']}"
      logger.info "[UsFoods]   Page text (first 400): #{page_snapshot['page_text'][0..400]}"
      logger.info "[UsFoods]   Buttons: #{page_snapshot['buttons']}"
      logger.info "[UsFoods]   Clickable elements: #{page_snapshot['clickables']}"
      logger.info "[UsFoods]   Visible modals: #{page_snapshot['modals']}"

      # If a modal/popup appeared with date or delivery options, handle it
      if page_snapshot['modals']&.any?
        logger.info "[UsFoods] Modal detected — attempting to select delivery date"
        handle_delivery_date_modal
        sleep 2
      end

      # After any modal handling, verify we're on the order page and the order exists.
      # Navigate back to /desktop/order to check.
      navigate_to("#{BASE_URL}/desktop/order")
      sleep 2

      post_state = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('ion-button, button');
          var visible = Array.from(buttons).filter(function(b) { return b.offsetParent !== null; });
          var texts = visible.map(function(b) { return (b.innerText || '').trim(); });

          var hasStartOrder = texts.some(function(t) { return t.toLowerCase().includes('start an order'); });
          var hasAddProducts = texts.some(function(t) { return t.toLowerCase() === 'add products'; });
          var cartButton = texts.find(function(t) { return t.match(/Cart:/); });
          var pageText = document.body ? document.body.innerText : '';
          var total = pageText.match(/Total:\s*\$(\S+)/);

          return {
            has_start_order: hasStartOrder,
            has_add_products: hasAddProducts,
            cart_button: cartButton,
            total: total ? total[1] : null,
            buttons: texts.filter(function(t) { return t.length > 0; }).slice(0, 15)
          };
        })()
      JS
      logger.info "[UsFoods] Order page after creation: #{post_state}"

      if post_state && post_state['has_start_order']
        logger.warn '[UsFoods] ⚠️ Order creation FAILED — "Start An Order" still visible on order page'
        logger.warn '[UsFoods] The order may not have been created. Items added via search may not be tracked.'
      else
        logger.info '[UsFoods] ✅ Order created successfully — ready to add items'
      end
    end

    # Handle a delivery date selection modal that may appear after clicking "Create Order"
    def handle_delivery_date_modal
      date_selected = browser.evaluate(<<~JS)
        (function() {
          var datePattern = /\\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\\b/i;
          var monthPattern = /\\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\\b/i;
          var numDatePattern = /\\b\\d{1,2}\\/\\d{1,2}\\b/;

          // Look for clickable date elements inside modals first, then page-wide
          var containers = document.querySelectorAll(
            'ion-modal, ion-alert, ion-popover, ion-action-sheet, [role="dialog"]'
          );
          var searchIn = [];
          for (var c of containers) {
            if (c.offsetParent !== null || getComputedStyle(c).display !== 'none') {
              searchIn.push(c);
            }
          }
          // Also search full page if no visible modals
          if (searchIn.length === 0) searchIn.push(document);

          for (var container of searchIn) {
            var elements = container.querySelectorAll(
              'ion-card, ion-item, ion-chip, ion-segment-button, ion-button, button, ' +
              '[class*="date"], [class*="delivery"], [class*="tile"], [class*="option"], ' +
              '[role="button"], [role="option"], [role="radio"], [role="listbox"] *'
            );

            for (var el of elements) {
              if (el.offsetParent === null) continue;
              var text = (el.innerText || '').trim();
              // Skip nav/header buttons
              if (text.match(/Products & Deals|My Business|My Orders|My Lists|Cancel|Create Order/i)) continue;
              if (text.match(datePattern) || text.match(monthPattern) || text.match(numDatePattern)) {
                el.click();
                return { clicked: true, text: text.substring(0, 80), method: 'date-in-modal' };
              }
            }

            // Try Pronto/delivery type
            for (var el of elements) {
              if (el.offsetParent === null) continue;
              var text = (el.innerText || '').trim().toLowerCase();
              if (text.includes('pronto') || text.includes('next day') || text.includes('regular')) {
                el.click();
                return { clicked: true, text: (el.innerText || '').trim().substring(0, 80), method: 'delivery-type' };
              }
            }
          }

          return { clicked: false };
        })()
      JS
      logger.info "[UsFoods] Delivery date modal selection: #{date_selected}"

      if date_selected && date_selected['clicked']
        sleep 1

        # Click any confirm/done/ok button in the modal
        confirmed = browser.evaluate(<<~JS)
          (function() {
            var targets = ['confirm', 'done', 'ok', 'select', 'continue', 'start order', 'submit', 'save'];
            // Check modals first
            var modals = document.querySelectorAll('ion-modal, ion-alert, ion-popover, [role="dialog"]');
            for (var modal of modals) {
              var btns = modal.querySelectorAll('button, ion-button, [role="button"]');
              for (var btn of btns) {
                if (btn.offsetParent === null) continue;
                var text = (btn.innerText || '').trim().toLowerCase();
                for (var t of targets) {
                  if (text === t || text.includes(t)) {
                    btn.click();
                    return { clicked: true, text: btn.innerText.trim() };
                  }
                }
              }
            }
            // Fallback: page-wide
            var allBtns = document.querySelectorAll('ion-button, button');
            for (var btn of allBtns) {
              if (btn.offsetParent === null) continue;
              var text = (btn.innerText || '').trim().toLowerCase();
              for (var t of targets) {
                if (text === t || text.includes(t)) {
                  if (btn.classList.contains('next-delivery-button')) continue;
                  if (btn.classList.contains('header-buttons')) continue;
                  btn.click();
                  return { clicked: true, text: btn.innerText.trim() };
                }
              }
            }
            return { clicked: false };
          })()
        JS
        logger.info "[UsFoods] Modal confirmation: #{confirmed}"
      end
    end

    # Add a single item to the active order on US Foods.
    #
    # On US Foods, "Add To List" adds to a *shopping list*, not the order.
    # The actual mechanism to add items to an active order is:
    #   1. Set quantity in the product card's ion-input.quantity-input-box
    #   2. Press Enter (or the Ionic change event triggers an add)
    #   3. If a modal appears (order selection), select the active order
    #
    # We also try clicking per-product add buttons if found, and fall back
    # to navigating directly to the product page where the order-add UI
    # may be different from the search results page.
    def add_item_to_order(sku, quantity)
      # Search for the product by SKU
      navigate_to("#{BASE_URL}/desktop/search2?searchText=#{sku}")
      sleep 2

      # Verify product was found
      page_text = begin
        browser.evaluate('document.body.innerText')
      rescue StandardError
        ''
      end
      if page_text.include?("couldn't find any matches") || page_text.include?('No results')
        raise ScrapingError, "Product SKU #{sku} not found on US Foods"
      end

      # DOM discovery: log the product card structure (inputs, buttons within the card)
      card_info = browser.evaluate(<<~JS)
        (function() {
          // US Foods product rows in search results
          var cards = document.querySelectorAll(
            'app-product-row, app-product-list-item, [data-cy*="product"], ' +
            '.product-card, .search-result-item, ion-card, .product-row'
          );
          var card = cards.length > 0 ? cards[0] : null;

          // Also find all quantity-related inputs on the page
          var qtyInputs = document.querySelectorAll('ion-input.quantity-input-box, input[type="number"], input[type="tel"]');
          var qtyInfo = Array.from(qtyInputs).map(function(el) {
            var rect = el.getBoundingClientRect();
            return {
              tag: el.tagName, class: el.className.substring(0, 80),
              value: el.value || '', visible: rect.width > 0
            };
          });

          // Find all clickable elements near quantity inputs (potential add buttons)
          var nearbyButtons = [];
          qtyInputs.forEach(function(qi) {
            var parent = qi.closest('app-product-row, app-product-list-item, ion-card, .product-row') || qi.parentElement;
            if (parent) {
              var btns = parent.querySelectorAll('ion-button, button, ion-icon, [role="button"]');
              btns.forEach(function(b) {
                nearbyButtons.push({
                  tag: b.tagName, text: (b.innerText || '').trim().substring(0, 40),
                  class: b.className ? b.className.substring(0, 60) : '',
                  icon: b.querySelector('ion-icon') ? b.querySelector('ion-icon').getAttribute('name') || '' : ''
                });
              });
            }
          });

          return {
            card_count: cards.length,
            card_tag: card ? card.tagName : null,
            card_text: card ? card.innerText.substring(0, 300) : null,
            qty_inputs: qtyInfo,
            nearby_buttons: nearbyButtons.slice(0, 10)
          };
        })()
      JS
      logger.info "[UsFoods] Product card DOM for SKU #{sku}: #{card_info}"

      # Check if the product is out of stock on US Foods.
      # The product card will show "Out of Stock" text when the item is unavailable.
      # We detect this BEFORE trying to add, to avoid crashing the whole order later.
      if card_info && card_info['card_text']&.match?(/out of stock/i)
        oos_message = card_info['card_text'][0..100]
        logger.warn "[UsFoods] SKU #{sku} is OUT OF STOCK on US Foods: #{oos_message}"
        raise ItemUnavailableError.new(
          "SKU #{sku} is out of stock on US Foods",
          items: [{ sku: sku.to_s, name: oos_message.strip }]
        )
      end

      # Capture order count badge BEFORE adding (to detect changes after)
      order_count_before = browser.evaluate(<<~JS)
        (function() {
          // Look for order count badge in header
          var badges = document.querySelectorAll('[data-cy*="order-count"], [data-cy*="cart-count"], .badge, ion-badge');
          for (var b of badges) {
            var num = parseInt(b.innerText);
            if (!isNaN(num)) return num;
          }
          return null;
        })()
      JS

      # Use Ferrum's CDP keyboard simulation to type the quantity.
      # JavaScript event dispatch (native setter + dispatchEvent) does NOT
      # trigger Angular/Ionic's change detection — the framework only responds
      # to real browser keyboard events sent through CDP's Input.dispatchKeyEvent.

      # Step 1: Focus and click the quantity input via JavaScript
      focused = browser.evaluate(<<~JS)
        (function() {
          var ionInput = document.querySelector('ion-input.quantity-input-box');
          if (!ionInput) return { ok: false, error: 'no ion-input.quantity-input-box found' };

          var nativeInput = ionInput.querySelector('input.native-input') || ionInput.querySelector('input');
          if (!nativeInput) return { ok: false, error: 'no native input inside ion-input' };

          // Click and focus the native input
          nativeInput.click();
          nativeInput.focus();

          // Select all existing text so typing replaces it
          nativeInput.select();

          return { ok: true, currentValue: nativeInput.value };
        })()
      JS
      logger.info "[UsFoods] Input focus for SKU #{sku}: #{focused}"

      unless focused && focused['ok']
        raise ScrapingError, "Could not focus quantity input for SKU #{sku}: #{focused&.dig('error')}"
      end

      sleep 0.3

      # Step 2: Type the quantity using REAL keyboard events via CDP
      # This sends keyDown + keyUp through Chrome's input pipeline,
      # which Angular/Ionic's event listeners will detect.
      quantity_str = quantity.to_s
      browser.keyboard.type(*quantity_str.chars)
      logger.info "[UsFoods] Typed '#{quantity_str}' via CDP keyboard for SKU #{sku}"

      sleep 0.5

      # Step 3: Press Tab to trigger blur → this confirms the add on US Foods
      browser.keyboard.type(:Tab)
      logger.info "[UsFoods] Pressed Tab to confirm add for SKU #{sku}"

      # Wait for the add to process
      sleep 2

      # Check if an order selection modal appeared (happens when multiple orders exist)
      modal_appeared = wait_for_order_modal(timeout: 3)

      if modal_appeared
        logger.info '[UsFoods] Order selection modal appeared — selecting active order'
        handle_order_selection_modal
        sleep 1
      end

      # DON'T navigate away to verify — this interrupts async adds.
      # Instead, check for immediate success indicators on the current page.
      # Bulk verification happens in add_to_cart after ALL items are added.
      check_immediate_add_result(sku, order_count_before)
    end

    # Handle the "Add to Order" modal — select the active order and confirm
    def handle_order_selection_modal
      # Select the active/existing order in the modal
      selected = browser.evaluate(<<~JS)
        (function() {
          var items = document.querySelectorAll(
            'ion-item, [class*="order-option"], ion-radio, ion-label, ion-radio-group ion-item'
          );
          // Prefer existing order (has a date like "2/23" or says "existing")
          for (var item of items) {
            var text = (item.innerText || '').trim();
            if (text.match(/existing/i) || text.match(/\\d{1,2}\\/\\d{1,2}/)) {
              item.click();
              return { selected: true, text: text.substring(0, 50), method: 'existing' };
            }
          }
          // Fallback: click first order option
          for (var item of items) {
            var text = (item.innerText || '').trim();
            if (text.match(/order/i)) {
              item.click();
              return { selected: true, text: text.substring(0, 50), method: 'first-order' };
            }
          }
          return { selected: false };
        })()
      JS
      logger.info "[UsFoods] Order selection: #{selected}"
      sleep 1

      # Click confirm/add button in the modal
      confirmed = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('ion-button, button');
          var targets = ['Add Product', 'Add Item', 'Add', 'Save', 'Confirm', 'Done', 'OK'];
          for (var btn of buttons) {
            if (btn.offsetParent === null) continue;
            var text = (btn.innerText || '').trim();
            for (var target of targets) {
              if (text === target || text.toLowerCase() === target.toLowerCase()) {
                btn.click();
                return { clicked: true, text: text };
              }
            }
          }
          return { clicked: false };
        })()
      JS
      logger.info "[UsFoods] Modal confirm: #{confirmed}"
    end

    # Quick check for immediate success indicators WITHOUT navigating away.
    # We trust the add and do bulk verification later in add_to_cart.
    def check_immediate_add_result(sku, count_before)
      # Check 1: Success toast with actual text (not just a badge number)
      toast_text = browser.evaluate(<<~JS)
        (function() {
          // Only check ion-toast (actual toast messages), not notification badges
          var toasts = document.querySelectorAll('ion-toast, [class*="toast-message"], [class*="snackbar"]');
          for (var t of toasts) {
            var text = (t.innerText || '').trim();
            // Must be a real message (more than just a number)
            if (text.length > 3) return text.substring(0, 150);
          }
          return null;
        })()
      JS

      if toast_text
        logger.info "[UsFoods] Toast message after add: #{toast_text}"
        if toast_text.match?(/added|updated|success/i)
          logger.info "[UsFoods] Item #{sku} confirmed added via toast"
          return true
        end
      end

      # Check 2: Order count badge increased
      order_count_after = browser.evaluate(<<~JS)
        (function() {
          var badges = document.querySelectorAll('[data-cy*="order-count"], [data-cy*="cart-count"], .badge, ion-badge');
          for (var b of badges) {
            var num = parseInt(b.innerText);
            if (!isNaN(num)) return num;
          }
          return null;
        })()
      JS

      if count_before && order_count_after && order_count_after > count_before
        logger.info "[UsFoods] Item #{sku} added — order count: #{count_before} → #{order_count_after}"
        return true
      end

      # Check 3: See if the quantity input now shows the value we set
      # (on US Foods, a filled quantity input means the item is on the order)
      qty_value = browser.evaluate(<<~JS)
        (function() {
          var input = document.querySelector('ion-input.quantity-input-box input.native-input') ||
                      document.querySelector('ion-input.quantity-input-box input');
          return input ? input.value : null;
        })()
      JS

      if qty_value.present? && qty_value.to_i > 0
        logger.info "[UsFoods] Quantity input shows #{qty_value} for SKU #{sku} — likely added"
        return true
      end

      # No immediate confirmation — log it but DON'T fail.
      # The add may be processing async. We'll verify all items in bulk.
      logger.warn "[UsFoods] No immediate confirmation for SKU #{sku} — will verify in bulk later"
      true # Optimistic — bulk verify will catch failures
    end

    # Verify all expected SKUs are on the order page. Called once after all
    # items have been added (avoids navigating away between adds).
    def verify_items_on_order_page(expected_skus)
      navigate_to("#{BASE_URL}/desktop/order")
      sleep 3

      # Poll until order items render (Angular/Ionic loads them async)
      # Look for ion-card elements, quantity inputs, or SKU text appearing
      order_page_text = ''
      attempts = 0
      max_attempts = 10 # 10 × 2s = 20s max wait

      loop do
        attempts += 1
        order_page_text = browser.evaluate('(document.body.innerText || "")') rescue ''

        # Check if any expected SKU is visible — means items have rendered
        any_sku_found = expected_skus.any? { |sku| order_page_text.include?(sku.to_s) }

        # Also check for order item indicators (quantity inputs, product cards)
        items_rendered = browser.evaluate(<<~JS) rescue 0
          (function() {
            var inputs = document.querySelectorAll('.quantity-input-box, [data-cy*="order-item"], ion-card .product-name');
            return inputs.length;
          })()
        JS

        if any_sku_found || items_rendered > 0
          logger.info "[UsFoods] Order page loaded: #{order_page_text.length} chars, #{items_rendered} item elements (attempt #{attempts})"
          break
        end

        if attempts >= max_attempts
          logger.warn "[UsFoods] Order page items did not render after #{attempts * 2}s (text_length=#{order_page_text.length})"
          break
        end

        sleep 2
      end

      found_skus = []
      missing_skus = []

      expected_skus.each do |sku|
        if order_page_text.include?(sku.to_s)
          found_skus << sku
        else
          missing_skus << sku
        end
      end

      logger.info "[UsFoods] Order page verification: #{found_skus.size}/#{expected_skus.size} SKUs found"

      if missing_skus.any?
        # Log order page DOM for debugging
        dom_state = browser.evaluate(<<~JS)
          (function() {
            var rows = document.querySelectorAll('[data-cy*="order-item"], [data-cy*="product-row"], .order-item, .line-item, ion-card');
            return {
              url: location.href,
              page_text_length: document.body.innerText.length,
              visible_items: rows.length,
              first_500: document.body.innerText.substring(0, 500)
            };
          })()
        JS
        logger.warn "[UsFoods] Missing SKUs: #{missing_skus}. DOM: #{dom_state}"
      end

      { found: found_skus, missing: missing_skus }
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

    def checkout(dry_run: false)
      effective_dry_run = dry_run || !CHECKOUT_LIVE
      logger.info "[UsFoods] checkout starting (dry_run=#{effective_dry_run}, CHECKOUT_LIVE=#{CHECKOUT_LIVE})"

      # Reuse the persistent browser from add_to_cart (order context is preserved)
      ensure_order_browser!

      begin
        # Step 2: Navigate to order/cart page
        # US Foods uses an order-based model — try the orders page first
        navigate_to("#{BASE_URL}/desktop/order")
        sleep 3

        # Step 3: DOM discovery logging
        page_url = browser.current_url rescue 'unknown'
        page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
        logger.info "[UsFoods] Cart/Order page URL: #{page_url}"
        logger.info "[UsFoods] Cart/Order page text (first 500): #{page_text[0..500]}"

        dom_info = browser.evaluate(<<~JS)
          (function() {
            return {
              url: window.location.href,
              title: document.title,
              has_price: !!document.body.innerText.match(/\\$\\d+\\.\\d{2}/),
              buttons: Array.from(document.querySelectorAll('ion-button, button'))
                .filter(function(b) { return b.offsetParent !== null; })
                .slice(0, 20)
                .map(function(b) { return { tag: b.tagName, text: (b.innerText||'').trim().substring(0, 50), classes: (b.className||'').substring(0, 80) }; }),
              inputs: Array.from(document.querySelectorAll('input'))
                .filter(function(i) { return i.offsetParent !== null; })
                .slice(0, 10)
                .map(function(i) { return { type: i.type, name: i.name, value: i.value, classes: (i.className||'').substring(0, 50) }; })
            };
          })()
        JS
        logger.info "[UsFoods] Cart/Order page DOM: #{dom_info.inspect}"

        # Step 4: Extract cart/order data
        cart_data = extract_cart_data_usf
        logger.info "[UsFoods] Cart: #{cart_data[:item_count]} items, subtotal=#{cart_data[:subtotal]}"

        # Step 5: Validate cart
        raise ScrapingError, 'Cart/order is empty' if cart_data[:item_count] == 0

        # Step 6: Check order minimum
        if cart_data[:subtotal] > 0 && cart_data[:subtotal] < ORDER_MINIMUM
          raise OrderMinimumError.new(
            'Order minimum not met',
            minimum: ORDER_MINIMUM,
            current_total: cart_data[:subtotal]
          )
        end

        # Step 7: Handle unavailable items — log a warning but DON'T crash the order.
        # If some items are OOS, the remaining items may still meet the minimum.
        # We'll report them in the dry run summary so the user knows.
        if cart_data[:unavailable_items].any?
          oos_names = cart_data[:unavailable_items].map { |i| i[:name] || i[:sku] }
          logger.warn "[UsFoods] #{cart_data[:unavailable_items].count} unavailable item(s) in cart: #{oos_names.join(', ')}"
          # Don't crash — just note them. The order total from the Cart button
          # already excludes OOS items (US Foods grays them out but keeps them visible).
        end

        # Step 8: Navigate to checkout/review page
        proceed_to_checkout_page_usf

        # Step 9: Extract checkout data
        checkout_data = extract_checkout_data_usf
        logger.info "[UsFoods] Checkout: total=#{checkout_data[:total]}, delivery=#{checkout_data[:delivery_date]}"

        # ═══════════════════════════════════════════
        # ═══ SAFETY GATE — DRY RUN CHECK ══════════
        # ═══════════════════════════════════════════
        if effective_dry_run
          logger.info "[UsFoods] DRY RUN COMPLETE — stopping before final submit"
          logger.info "[UsFoods] Would have placed order: total=#{checkout_data[:total]}"

          return {
            confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
            total: checkout_data[:total] || cart_data[:subtotal],
            delivery_date: checkout_data[:delivery_date],
            dry_run: true,
            cart_items: cart_data[:items],
            checkout_summary: checkout_data
          }
        end

        # Step 10: LIVE ORDER — Click final submit
        logger.warn "[UsFoods] PLACING LIVE ORDER — clicking submit"
        click_place_order_button_usf

        # Step 11: Wait for confirmation
        confirmation = wait_for_order_confirmation_usf

        logger.info "[UsFoods] Order placed: #{confirmation[:confirmation_number]}"
        confirmation
      ensure
        close_order_browser!
      end
    end

    def clear_cart
      logger.info '[UsFoods] Clearing cart/order...'

      # Use persistent order browser (same one add_to_cart and checkout will use)
      ensure_order_browser!

      # Navigate to orders page
      navigate_to("#{BASE_URL}/desktop/order")
      sleep 2

      # Check if there's an existing order with items by reading the Cart button
      cart_info = browser.evaluate(<<~JS)
        (function() {
          var buttons = document.querySelectorAll('ion-button, button');
          for (var btn of buttons) {
            var text = (btn.innerText || '').trim();
            // "Cart: $279.38 (4)" pattern
            var match = text.match(/Cart:\\s*\\$(\\S+)\\s*\\((\\d+)\\)/);
            if (match) return { total: match[1], count: parseInt(match[2]), text: text };
          }
          return null;
        })()
      JS

      if cart_info
        logger.info "[UsFoods] Existing order found: #{cart_info['text']}"
      else
        logger.info '[UsFoods] No existing cart/order detected — nothing to clear'
        return
      end

      # "Cancel Order" button is often below the items list (scrolled off-screen).
      # Scroll to the bottom of the page first, then search ALL buttons
      # (including those not initially in view). Don't filter by offsetParent
      # since the button may have been lazily rendered.
      browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
      sleep 1.5

      cleared = browser.evaluate(<<~JS)
        (function() {
          // Search ALL buttons (visible or not) — "Cancel Order" may be
          // off-screen or just scrolled into view after our scroll.
          var buttons = document.querySelectorAll('ion-button, button');
          var targets = ['cancel order', 'empty order', 'clear order', 'delete order', 'remove all'];
          for (var btn of buttons) {
            var text = (btn.innerText || '').trim().toLowerCase();
            for (var target of targets) {
              if (text.includes(target)) {
                // Scroll it into view and click
                btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                btn.click();
                return { cleared: true, text: btn.innerText.trim() };
              }
            }
          }
          return { cleared: false };
        })()
      JS

      if cleared && cleared['cleared']
        logger.info "[UsFoods] Clicked '#{cleared['text']}' to cancel order"
        sleep 2

        # Handle confirmation dialog — US Foods asks "Are you sure?"
        # Try multiple times since the modal may take a moment to appear
        3.times do |attempt|
          confirmed = browser.evaluate(<<~JS)
            (function() {
              // Check for modal/dialog/alert overlay
              var overlays = document.querySelectorAll(
                'ion-alert, ion-modal, [class*="alert"], [class*="dialog"], [class*="modal"], [role="dialog"]'
              );
              for (var overlay of overlays) {
                var btns = overlay.querySelectorAll('button, ion-button, [class*="alert-button"]');
                for (var btn of btns) {
                  var text = (btn.innerText || '').trim().toLowerCase();
                  if (text === 'yes' || text.includes('yes') || text === 'confirm' ||
                      text === 'ok' || text === 'delete' || text.includes('cancel order')) {
                    btn.click();
                    return { confirmed: true, text: btn.innerText.trim() };
                  }
                }
              }

              // Fallback: check all visible buttons on page
              var allBtns = document.querySelectorAll('ion-button, button');
              for (var btn of allBtns) {
                if (btn.offsetParent === null) continue;
                var text = (btn.innerText || '').trim().toLowerCase();
                if (text === 'yes' || text === 'yes, cancel' || text === 'confirm') {
                  btn.click();
                  return { confirmed: true, text: btn.innerText.trim() };
                }
              }
              return { confirmed: false };
            })()
          JS

          if confirmed && confirmed['confirmed']
            logger.info "[UsFoods] Cancellation confirmed: #{confirmed['text']}"
            sleep 2
            break
          end
          sleep 1
        end

        # Verify the order was actually cancelled
        sleep 1
        post_cancel = browser.evaluate(<<~JS)
          (function() {
            var buttons = document.querySelectorAll('ion-button, button');
            for (var btn of buttons) {
              var text = (btn.innerText || '').trim();
              if (text.match(/Cart:/)) return { cart: text };
              if (text.match(/Start An Order/i)) return { empty: true };
            }
            return { unknown: true };
          })()
        JS
        logger.info "[UsFoods] Post-cancel state: #{post_cancel}"
      else
        # "Cancel Order" not found even after scrolling.
        # Fall back: set all item quantities to 0 to empty the order.
        logger.warn '[UsFoods] Cancel Order button not found — clearing items by setting quantities to 0'

        items_cleared = browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('ion-input.quantity-input-box input.native-input');
            var count = 0;
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            for (var input of inputs) {
              if (input.value && parseInt(input.value) > 0) {
                nativeSetter.call(input, '0');
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', keyCode: 13, bubbles: true }));
                count++;
              }
            }
            return count;
          })()
        JS
        logger.info "[UsFoods] Set #{items_cleared} item quantities to 0"
        sleep 2

        # Also try scrolling to find Cancel Order one more time
        browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
        sleep 1

        retry_cancel = browser.evaluate(<<~JS)
          (function() {
            var buttons = document.querySelectorAll('ion-button, button');
            for (var btn of buttons) {
              var text = (btn.innerText || '').trim().toLowerCase();
              if (text.includes('cancel order')) {
                btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                btn.click();
                return { found: true, text: btn.innerText.trim() };
              }
            }
            return { found: false };
          })()
        JS

        if retry_cancel && retry_cancel['found']
          logger.info "[UsFoods] Found Cancel Order on retry: #{retry_cancel['text']}"
          sleep 2
          # Confirm
          browser.evaluate(<<~JS)
            (function() {
              var btns = document.querySelectorAll('ion-button, button, [class*="alert-button"]');
              for (var btn of btns) {
                var text = (btn.innerText || '').trim().toLowerCase();
                if (text === 'yes' || text.includes('yes') || text === 'confirm') {
                  btn.click(); return true;
                }
              }
              return false;
            })()
          JS
          sleep 2
        end
      end

      logger.info '[UsFoods] Cart clearing complete'
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
        sleep 3
        handle_kmsi_prompt # Click "Yes" on "Stay signed in?" if B2C shows it
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

    # Detect and click "Yes" on the Azure B2C KMSI (Keep Me Signed In) prompt.
    # After MFA or password auth, B2C may show a "Would you like to stay signed in
    # on this device?" interstitial page with Yes/No buttons. Clicking "Yes" sets a
    # persistent remember-me cookie that survives browser restarts — critical for
    # session persistence since we destroy the Chrome process after each operation.
    #
    # Standard B2C element IDs:
    #   #idBtn_Accept => "Yes" button
    #   #idBtn_Back   => "No" button
    #   #idSIButton9  => Primary action button (sometimes used for KMSI submit)
    def handle_kmsi_prompt
      clicked = browser.evaluate(<<~JS)
        (function() {
          // Azure B2C standard KMSI "Yes" button
          var acceptBtn = document.getElementById('idBtn_Accept');
          if (acceptBtn && acceptBtn.offsetParent !== null) {
            acceptBtn.click();
            return 'idBtn_Accept';
          }

          // B2C primary action button (alternate KMSI rendering)
          var primaryBtn = document.getElementById('idSIButton9');
          if (primaryBtn && primaryBtn.offsetParent !== null) {
            primaryBtn.click();
            return 'idSIButton9';
          }

          // Fallback: any visible button with text "Yes"
          var buttons = document.querySelectorAll('button, input[type="submit"], input[type="button"]');
          for (var i = 0; i < buttons.length; i++) {
            var text = (buttons[i].innerText || buttons[i].value || '').trim().toLowerCase();
            if (text === 'yes') {
              buttons[i].click();
              return 'yes-text-match';
            }
          }

          return null;
        })()
      JS

      if clicked
        logger.info "[UsFoods] Handled KMSI 'Stay signed in' prompt: #{clicked}"
        sleep 2
        true
      else
        false
      end
    rescue StandardError => e
      logger.debug "[UsFoods] KMSI prompt check error: #{e.message}"
      false
    end

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

        # Check for KMSI "Stay signed in?" prompt before trying Continue buttons.
        # B2C may show this interstitial after MFA — must click "Yes" to get a
        # persistent session cookie, then the redirect will follow automatically.
        if handle_kmsi_prompt
          next # Loop back to check for redirect
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
            // Scroll incrementally by viewport height so virtual scroll renders
            // new items. Jumping to scrollHeight skips all middle content.
            vScroll.scrollTop += vScroll.clientHeight;
            return;
          }

          // Fallback: any element with cdk-virtual-scroll in class
          var cdkEl = document.querySelector('[class*="cdk-virtual-scroll"]');
          if (cdkEl) {
            cdkEl.scrollTop += cdkEl.clientHeight;
            return;
          }

          // Last resort: window scroll
          window.scrollBy(0, window.innerHeight);
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

              // Case price extraction (3 methods, matching scrape_product logic)
              var price = null;

              // Method 1: "$XX.XX CS" or "$XX.XX/CS" pattern (with optional slash/space)
              var csMatch = text.match(/\\$(\\d+[,\\d]*\\.\\d{2})\\s*[\\/]?\\s*CS/i);
              if (csMatch) {
                price = parseFloat(csMatch[1].replace(',', ''));
              }

              // Method 2: data-cy case price element (Angular data attributes)
              if (!price) {
                var casePriceEl = card.querySelector('[data-cy*="case-price"], [data-cy*="product-price"]:not([data-cy*="unit"])');
                if (casePriceEl) {
                  var cpm = casePriceEl.innerText.match(/\\$(\\d+[,\\d]*\\.\\d{2})/);
                  if (cpm) price = parseFloat(cpm[1].replace(',', ''));
                }
              }

              // Method 3: Find prices excluding per-unit prices (which have /unit suffix)
              if (!price) {
                var priceRegex = /\\$(\\d+[,\\d]*\\.\\d{2})(\\/[a-zA-Z]+)?/g;
                var pm;
                var casePrices = [];
                while ((pm = priceRegex.exec(text)) !== null) {
                  // Only include prices that DON'T have a per-unit suffix like /LB, /OZ
                  // but DO include /CS (case) prices
                  if (!pm[2] || pm[2].match(/\\/CS/i)) {
                    casePrices.push(parseFloat(pm[1].replace(',', '')));
                  }
                }
                if (casePrices.length > 0) price = Math.max.apply(null, casePrices);
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

      priceless_count = products.count { |p| p['price'].nil? }
      if priceless_count > 0 && products.any?
        logger.warn "[UsFoods] #{priceless_count}/#{products.size} products extracted without a price"
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

    # ─── Checkout helper methods ───────────────────────────────────

    def extract_cart_data_usf
      cart_data = browser.evaluate(<<~JS)
        (function() {
          var result = { items: [], subtotal: 0, item_count: 0, unavailable: [] };
          var pageText = document.body ? document.body.innerText : '';

          // PRIMARY: Extract total from "Cart: $655.55 (9)" button
          var buttons = document.querySelectorAll('ion-button, button');
          for (var btn of buttons) {
            var text = (btn.innerText || '').trim();
            var cartMatch = text.match(/Cart:\\s*\\$([\\d,]+\\.\\d{2})\\s*\\((\\d+)\\)/);
            if (cartMatch) {
              result.subtotal = parseFloat(cartMatch[1].replace(',', ''));
              result.item_count = parseInt(cartMatch[2]);
              break;
            }
          }

          // FALLBACK: Extract from "Total Products: N" and dollar amount
          if (result.subtotal === 0) {
            var totalMatch = pageText.match(/\\$(\\d[\\d,]*\\.\\d{2})\\s*$/m);
            if (totalMatch) result.subtotal = parseFloat(totalMatch[1].replace(',', ''));

            var prodCount = pageText.match(/Total Products:\\s*(\\d+)/i);
            if (prodCount) result.item_count = parseInt(prodCount[1]);
          }

          // Extract individual items from ion-card elements.
          // Only include cards that have a quantity input with value > 0
          // (items actually on the order, NOT "Did You Forget?" recommendations).
          var cards = document.querySelectorAll('ion-card');
          cards.forEach(function(card) {
            var qtyInput = card.querySelector('ion-input.quantity-input-box input.native-input') ||
                           card.querySelector('ion-input.quantity-input-box input');
            if (!qtyInput) return;

            var qty = parseInt(qtyInput.value);
            if (!qty || qty <= 0) return; // Skip items not on the order

            var text = card.innerText || '';
            var skuMatch = text.match(/#(\\d{5,})/);
            var nameLines = text.split('\\n').filter(function(l) { return l.trim().length > 0; });

            // Extract case price — "$XX.XX cs" pattern
            var price = null;
            var csMatch = text.match(/\\$(\\d+[,\\d]*\\.\\d{2})\\s*cs/i);
            if (csMatch) {
              price = parseFloat(csMatch[1].replace(',', ''));
            } else {
              // Fallback: first dollar amount that's not a per-unit price
              var prices = text.match(/\\$(\\d+[,\\d]*\\.\\d{2})(?!\\s*\\/)/g);
              if (prices && prices.length > 0) {
                price = parseFloat(prices[0].replace(/[\\$,]/g, ''));
              }
            }

            var isUnavailable = /out of stock|unavailable|discontinued/i.test(text);

            var item = {
              name: (nameLines[0] + ' ' + (nameLines[1] || '')).trim().substring(0, 80),
              sku: skuMatch ? skuMatch[1] : null,
              price: price || 0,
              quantity: qty
            };

            result.items.push(item);
            if (isUnavailable) result.unavailable.push(item);
          });

          // If we found items from cards, use that count
          if (result.items.length > 0 && result.item_count === 0) {
            result.item_count = result.items.length;
          }

          return result;
        })()
      JS

      logger.info "[UsFoods] Cart extraction: items=#{(cart_data['items'] || []).size}, subtotal=#{cart_data['subtotal']}, count=#{cart_data['item_count']}"

      {
        items: (cart_data['items'] || []).map { |i| { name: i['name'], sku: i['sku'], price: i['price'], quantity: i['quantity'] } },
        subtotal: cart_data['subtotal'] || 0,
        item_count: cart_data['item_count'] || 0,
        unavailable_items: (cart_data['unavailable'] || []).map { |i| { name: i['name'], sku: i['sku'], message: 'Unavailable' } }
      }
    end

    def proceed_to_checkout_page_usf
      # US Foods may have "Submit Order" / "Checkout" / "Review Order" button
      clicked = browser.evaluate(<<~JS)
        (function() {
          var exclude = /search|clear|close|cancel|filter|back/i;
          var targets = ['submit order', 'checkout', 'review order', 'proceed', 'place order'];
          var elements = document.querySelectorAll('ion-button, button, a[class*="btn"]');

          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var text = (el.innerText || '').trim().toLowerCase();
            if (exclude.test(text)) continue;
            for (var target of targets) {
              if (text.includes(target)) {
                el.scrollIntoView({ behavior: 'instant', block: 'center' });
                el.click();
                return { clicked: true, text: el.innerText.trim(), tag: el.tagName, method: 'text-match' };
              }
            }
          }

          // Phase 2: data-cy attributes
          var dcElements = document.querySelectorAll('[data-cy*="submit"], [data-cy*="checkout"], [data-cy*="review-order"]');
          for (var el of dcElements) {
            if (el.offsetParent !== null) {
              el.click();
              return { clicked: true, text: el.innerText.trim(), dataCy: el.getAttribute('data-cy'), method: 'data-cy' };
            }
          }

          return { clicked: false };
        })()
      JS

      if clicked && clicked['clicked']
        logger.info "[UsFoods] Clicked checkout button: #{clicked.inspect}"
      else
        logger.warn '[UsFoods] Could not find checkout button — may already be on review page'
      end

      sleep 3

      # Log the checkout/review page state
      page_url = browser.current_url rescue 'unknown'
      page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
      logger.info "[UsFoods] Checkout page URL: #{page_url}"
      logger.info "[UsFoods] Checkout page text (first 500): #{page_text[0..500]}"
    end

    def extract_checkout_data_usf
      checkout_data = browser.evaluate(<<~JS)
        (function() {
          var text = document.body ? document.body.innerText : '';
          var result = { total: 0, delivery_date: null, summary_text: text.substring(0, 1000) };

          // Total extraction
          var totalPatterns = [
            /order\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /estimated\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /subtotal[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /total[:\\s]*\\$([\\d,]+\\.\\d{2})/i
          ];
          for (var p of totalPatterns) {
            var m = text.match(p);
            if (m) { result.total = parseFloat(m[1].replace(',', '')); break; }
          }

          // Delivery date extraction
          var datePatterns = [
            /deliver(?:y|s)?[:\\s]*(\\w+day,?\\s*\\w+\\s+\\d{1,2})/i,
            /deliver(?:y|s)?\\s*(?:date)?[:\\s]*(\\d{1,2}\\/\\d{1,2}\\/\\d{2,4})/i,
            /deliver(?:y|s)?\\s*(?:date)?[:\\s]*(\\w+\\s+\\d{1,2},?\\s*\\d{4})/i,
            /(\\d{1,2}\\/\\d{1,2}\\/\\d{2,4})/
          ];
          for (var p of datePatterns) {
            var m = text.match(p);
            if (m) { result.delivery_date = m[1]; break; }
          }

          // Buttons for diagnostics
          result.buttons = Array.from(document.querySelectorAll('ion-button, button'))
            .filter(function(b) { return b.offsetParent !== null; })
            .slice(0, 15)
            .map(function(b) { return { text: (b.innerText||'').trim().substring(0, 50), tag: b.tagName, classes: (b.className||'').substring(0, 80) }; });

          return result;
        })()
      JS

      logger.info "[UsFoods] Checkout data: #{checkout_data.inspect}"

      {
        total: checkout_data['total'] || 0,
        delivery_date: checkout_data['delivery_date'],
        summary_text: checkout_data['summary_text'],
        buttons: checkout_data['buttons'] || []
      }
    end

    def click_place_order_button_usf
      clicked = browser.evaluate(<<~JS)
        (function() {
          var exclude = /search|clear|close|cancel|filter|back|add/i;
          var targets = ['place order', 'submit order', 'confirm order', 'complete order'];
          var elements = document.querySelectorAll('ion-button, button');
          for (var el of elements) {
            if (el.offsetParent === null) continue;
            var text = (el.innerText || '').trim().toLowerCase();
            if (exclude.test(text)) continue;
            for (var target of targets) {
              if (text.includes(target)) {
                el.scrollIntoView({ behavior: 'instant', block: 'center' });
                el.click();
                return { clicked: true, text: el.innerText.trim() };
              }
            }
          }

          // Fallback: data-cy
          var dcElements = document.querySelectorAll('[data-cy*="place-order"], [data-cy*="submit-order"], [data-cy*="confirm-order"]');
          for (var el of dcElements) {
            if (el.offsetParent !== null) {
              el.click();
              return { clicked: true, text: el.innerText.trim(), method: 'data-cy' };
            }
          }

          return { clicked: false };
        })()
      JS

      raise ScrapingError, 'Could not find place order button' unless clicked && clicked['clicked']

      logger.info "[UsFoods] Clicked place order: #{clicked.inspect}"
    end

    def wait_for_order_confirmation_usf
      start_time = Time.current
      timeout = 30

      loop do
        page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''

        if page_text.match?(/confirmation|order\s*(?:placed|submitted|received)|thank\s*you|order\s*#/i)
          conf_match = page_text.match(/order\s*#?\s*[:\s]*([A-Z0-9-]+)/i) ||
                       page_text.match(/confirmation\s*#?\s*[:\s]*([A-Z0-9-]+)/i) ||
                       page_text.match(/#(\d{5,})/)
          total_match = page_text.match(/total[:\s]*\$([\d,]+\.\d{2})/i)
          date_match = page_text.match(/deliver(?:y|s)?[:\s]*([\w\s,]+\d{1,2})/i)

          return {
            confirmation_number: conf_match ? conf_match[1] : "USF-#{Time.current.strftime('%Y%m%d%H%M%S')}",
            total: total_match ? total_match[1].gsub(',', '').to_f : nil,
            delivery_date: date_match ? date_match[1] : nil
          }
        end

        if page_text.match?(/error|failed|could not|unable to/i) && !page_text.match?(/confirmation|success|submitted/i)
          raise ScrapingError, "Checkout failed: #{page_text[0..300]}"
        end

        raise ScrapingError, 'Checkout confirmation timeout (30s)' if Time.current - start_time > timeout

        sleep 1
      end
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
