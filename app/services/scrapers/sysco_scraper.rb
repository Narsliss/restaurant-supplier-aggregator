module Scrapers
  class SyscoScraper < BaseScraper
    BASE_URL = 'https://shop.sysco.com'.freeze
    LOGIN_URL = 'https://secure.sysco.com/'.freeze
    CATALOG_URL = 'https://shop.sysco.com/app/catalog'.freeze
    LISTS_URL = 'https://shop.sysco.com/app/lists'.freeze
    ORDER_MINIMUM = 0.00 # Unknown — will be determined during testing
    PRODUCTS_PER_PAGE = 24
    MAX_PAGES_PER_TERM = 5

    LOGGED_IN_SELECTORS = [
      "a[href*='account']", "a[href*='logout']", "a[href*='sign-out']",
      '.account-menu', '.user-nav', '.user-menu',
      "[data-testid='user-menu']", "[data-testid='account']",
      "button[aria-label*='account']", "button[aria-label*='Account']"
    ].freeze

    # ----------------------------------------------------------------
    # Browser setup — stealth mode (Sysco is enterprise-scale, expect WAF)
    # ----------------------------------------------------------------

    def with_browser
      @browser = Ferrum::Browser.new(**build_stealth_browser_opts)
      setup_network_interception(@browser)
      inject_stealth_scripts(@browser)

      yield(browser)
    ensure
      browser&.quit
    end

    # ----------------------------------------------------------------
    # Public API — Authentication
    # ----------------------------------------------------------------

    def login
      with_browser do
        if restore_session && logged_in?
          logger.info '[Sysco] Session restored successfully'
          save_session
          return true
        end

        perform_login_steps
        sleep 3

        if logged_in?
          save_session
          credential.mark_active!
          true
        else
          diagnose_login_failure
          raise AuthenticationError, 'Login completed but not authenticated'
        end
      end
    end

    def logged_in?
      current_url = begin
        browser.current_url.to_s
      rescue StandardError
        ''
      end

      # shop.sysco.com/app/ is the authenticated SPA
      return true if current_url.include?('shop.sysco.com/app')

      # Check for user account UI elements
      LOGGED_IN_SELECTORS.any? do |sel|
        browser.at_css(sel)
      rescue StandardError
        false
      end
    end

    def soft_refresh
      with_browser do
        if restore_session && logged_in?
          save_session
          return true
        end
      end
      false
    rescue StandardError => e
      logger.warn "[Sysco] Soft refresh failed: #{e.message}"
      false
    end

    # ----------------------------------------------------------------
    # Public API — Catalog Search
    # ----------------------------------------------------------------

    def scrape_catalog(search_terms, max_per_term: 20, &on_batch)
      results = []
      seen_skus = Set.new

      with_browser do
        # Restore session or do fresh login
        unless restore_session && logged_in?
          perform_login_steps
          sleep 2
          raise AuthenticationError, 'Could not log in for catalog import' unless logged_in?
          save_session
        end
        dismiss_promo_modals

        search_terms.each do |term|
          begin
            logger.info "[Sysco] Searching catalog for: #{term}"
            products = search_supplier_catalog(term, max: max_per_term)

            new_products = products.reject { |p| seen_skus.include?(p[:supplier_sku]) }
            new_products.each { |p| seen_skus.add(p[:supplier_sku]) }

            if new_products.any?
              logger.info "[Sysco] Found #{new_products.size} new products for '#{term}' (#{products.size - new_products.size} dupes)"
              if block_given?
                yield(new_products)
              else
                results.concat(new_products)
              end
            else
              logger.info "[Sysco] No new products for '#{term}'"
            end
          rescue Ferrum::TimeoutError, Ferrum::PendingConnectionsError => e
            logger.warn "[Sysco] Timeout searching '#{term}': #{e.message}"
          rescue StandardError => e
            logger.error "[Sysco] Error searching '#{term}': #{e.class}: #{e.message}"
          end
        end
      end

      logger.info "[Sysco] Catalog scrape complete: #{seen_skus.size} total unique products"
      results
    end

    def search_supplier_catalog(term, max: 20)
      products = []
      pages_to_scrape = [(max.to_f / PRODUCTS_PER_PAGE).ceil, MAX_PAGES_PER_TERM].min

      pages_to_scrape.times do |page_idx|
        page_num = page_idx + 1
        url = "#{CATALOG_URL}?q=#{CGI.escape(term)}&page=#{page_num}"
        logger.info "[Sysco] Fetching search page #{page_num}: #{url}"

        navigate_to(url)
        sleep 3

        # Wait for product grid to render
        grid_loaded = wait_for_selector('[class*="product"]', timeout: 10)
        unless grid_loaded
          logger.warn "[Sysco] No product grid found on page #{page_num}"
          break
        end

        page_products = extract_search_products
        logger.info "[Sysco] Extracted #{page_products.size} products from page #{page_num}"

        products.concat(page_products)
        break if products.size >= max

        # Check if there's a next page
        has_next = browser.evaluate(<<~JS)
          (function() {
            // Look for the > next arrow in pagination
            var arrows = document.querySelectorAll('button, a, li');
            for (var i = 0; i < arrows.length; i++) {
              var text = (arrows[i].innerText || '').trim();
              if (text === '>' || text === '›') return true;
            }
            // Or check if current page < last page
            var pages = document.querySelectorAll('[class*="pagination"] a, [class*="pagination"] button, [class*="pagination"] li');
            return pages.length > 0;
          })()
        JS
        break unless has_next
      end

      products.first(max)
    end

    # ----------------------------------------------------------------
    # Public API — List / Order Guide Scraping
    # ----------------------------------------------------------------

    def scrape_lists
      with_browser do
        unless restore_session && logged_in?
          perform_login_steps
          sleep 2
          raise AuthenticationError, 'Could not log in for list import' unless logged_in?
          save_session
        end
        dismiss_promo_modals

        scrape_supplier_lists
      end
    end

    def scrape_supplier_lists
      logger.info '[Sysco] Navigating to Lists page...'
      navigate_to(LISTS_URL)
      sleep 3

      # Wait for sidebar to render
      wait_for_selector('[class*="sidebar"], [class*="list-nav"], [class*="menu"]', timeout: 10)

      # Extract list metadata from sidebar
      list_names = extract_list_sidebar
      logger.info "[Sysco] Found #{list_names.size} user lists: #{list_names.map { |l| l[:name] }.join(', ')}"

      lists = []
      list_names.each_with_index do |list_meta, idx|
        begin
          logger.info "[Sysco] Scraping list: #{list_meta[:name]}"

          # Click the list in the sidebar
          click_sidebar_list(list_meta[:name])
          sleep 2

          # Wait for items table to load
          wait_for_list_items

          # Extract items from the table
          items = extract_list_items
          logger.info "[Sysco] Extracted #{items.size} items from '#{list_meta[:name]}'"

          lists << {
            name: list_meta[:name],
            remote_id: list_meta[:remote_id] || list_meta[:name].parameterize,
            url: LISTS_URL,
            list_type: 'custom',
            items: items
          }
        rescue StandardError => e
          logger.error "[Sysco] Error scraping list '#{list_meta[:name]}': #{e.class}: #{e.message}"
        end
      end

      lists
    end

    # ----------------------------------------------------------------
    # Public API — Ordering (out of scope)
    # ----------------------------------------------------------------

    def scrape_prices(product_skus)
      raise NotImplementedError, 'Sysco price scraping not yet implemented'
    end

    def add_to_cart(items, delivery_date: nil)
      raise NotImplementedError, 'Sysco ordering not yet implemented'
    end

    def checkout(dry_run: false)
      raise NotImplementedError, 'Sysco ordering not yet implemented'
    end

    private

    # ----------------------------------------------------------------
    # Login flow — hybrid password + optional MFA
    # ----------------------------------------------------------------

    def perform_login_steps
      logger.info "[Sysco] Starting login for #{credential.username}"

      # Step 1: Navigate to Sysco's authentication portal
      navigate_to(LOGIN_URL)
      sleep 3
      apply_stealth

      log_page_state('After navigating to login page')

      # Step 2: Find and fill the email/username field
      email_filled = fill_login_email
      unless email_filled
        diagnose_login_failure
        raise AuthenticationError, 'Could not find or fill email field on secure.sysco.com'
      end
      logger.info '[Sysco] Email entered, clicking Next...'
      sleep 1

      # Step 2b: Click "Next" to advance past the email step
      click_next_button
      logger.info '[Sysco] Next clicked, waiting for password field...'
      sleep 3

      # Step 3: Fill password field (appears via JavaScript after email)
      password_filled = fill_login_password
      unless password_filled
        diagnose_login_failure
        raise AuthenticationError, 'Password field did not appear after entering email'
      end
      logger.info '[Sysco] Password entered'

      # Step 4: Check for "remember me" and submit
      check_remember_me
      click_login_submit
      logger.info '[Sysco] Login form submitted, waiting for response...'
      sleep 5

      # Step 5: Check what happened — success, MFA, second login, or error
      log_page_state('After first login submit')

      # Check if we're already logged in (no MFA, no second login)
      if logged_in?
        logger.info '[Sysco] Login successful (no MFA)'
        dismiss_promo_modals
        return
      end

      # Check for login errors before proceeding
      detect_login_errors

      # Check for MFA prompt (optional — some Sysco accounts have it, some don't)
      if handle_mfa_if_prompted
        logger.info '[Sysco] MFA completed successfully'
        sleep 3
        wait_for_post_login_redirect
        return
      end

      # Step 6: Handle second login page (shop.sysco.com/auth/login)
      # secure.sysco.com often redirects to shop.sysco.com/auth/login
      # which presents its own email + password form.
      current_url = browser.current_url rescue ''
      if current_url.include?('shop.sysco.com/auth/login') || current_url.include?('/auth/')
        logger.info "[Sysco] Redirected to second login page: #{current_url}"
        sleep 2
        log_page_state('Second login page')

        email_filled = fill_login_email
        if email_filled
          logger.info '[Sysco] Second login — email entered, clicking Next...'
          sleep 1

          click_next_button
          logger.info '[Sysco] Second login — Next clicked, waiting for password...'
          sleep 3

          password_filled = fill_login_password
          if password_filled
            logger.info '[Sysco] Second login — password entered'
            check_remember_me
            click_login_submit
            logger.info '[Sysco] Second login submitted, waiting...'
            sleep 5
            log_page_state('After second login submit')
          end
        end
      end

      # Final check — should be logged in now
      sleep 3 unless logged_in?
      if logged_in?
        logger.info '[Sysco] Login successful'
        dismiss_promo_modals
        return
      end

      # Still not logged in — something went wrong
      diagnose_login_failure
      raise AuthenticationError, 'Login failed — not authenticated after both login stages'
    end

    # ----------------------------------------------------------------
    # Promo modal dismissal
    # ----------------------------------------------------------------

    def dismiss_promo_modals
      dismissed = browser.evaluate(<<~JS)
        (function() {
          // Try common close button patterns for the "Save a bunch!" modal
          var selectors = [
            'button[aria-label="Close"]',
            'button[aria-label="close"]',
            'button.close',
            '.modal-close',
            '[class*="modal"] button[class*="close"]',
            '[class*="dialog"] button[class*="close"]',
            '[class*="overlay"] button[class*="close"]'
          ];
          for (var i = 0; i < selectors.length; i++) {
            var btn = document.querySelector(selectors[i]);
            if (btn && btn.offsetHeight > 0) { btn.click(); return 'selector:' + selectors[i]; }
          }

          // Fallback: find any visible × or X button in a modal/overlay
          var buttons = document.querySelectorAll('button, [role="button"]');
          for (var i = 0; i < buttons.length; i++) {
            var text = (buttons[i].innerText || '').trim();
            if ((text === '×' || text === 'X' || text === '✕' || text === '✖') && buttons[i].offsetHeight > 0) {
              buttons[i].click();
              return 'x_button';
            }
          }

          // Try clicking outside the modal to dismiss
          var overlays = document.querySelectorAll('[class*="overlay"], [class*="backdrop"]');
          for (var i = 0; i < overlays.length; i++) {
            if (overlays[i].offsetHeight > 0) { overlays[i].click(); return 'overlay'; }
          }

          return false;
        })()
      JS

      if dismissed
        logger.info "[Sysco] Dismissed promo modal via: #{dismissed}"
        sleep 1
      end
    rescue StandardError => e
      logger.debug "[Sysco] No promo modal to dismiss: #{e.message}"
    end

    # ----------------------------------------------------------------
    # Catalog search helpers
    # ----------------------------------------------------------------

    # Wait for a CSS selector to appear on the page
    def wait_for_selector(selector, timeout: 10)
      timeout.times do
        found = browser.evaluate("!!document.querySelector('#{selector}')")
        return true if found
        sleep 1
      end
      false
    end

    # Extract product data from the search results grid
    def extract_search_products
      browser.evaluate(<<~JS)
        (function() {
          var products = [];
          // Product cards — each card contains: SKU, brand, name+pack, price
          // Try multiple container selectors since we don't know exact classes
          var cards = document.querySelectorAll('[class*="product-card"], [class*="productCard"], [class*="product-tile"], [class*="productTile"]');
          if (cards.length === 0) {
            // Fallback: look for grid items that contain Add to Cart buttons
            cards = document.querySelectorAll('[class*="grid"] > div, [class*="catalog"] [class*="item"]');
          }
          if (cards.length === 0) {
            // Last resort: find elements containing price patterns
            var allDivs = document.querySelectorAll('div');
            var cardSet = [];
            for (var d = 0; d < allDivs.length; d++) {
              var text = allDivs[d].innerText || '';
              if (text.match(/\\$\\d+\\.\\d{2}\\s*(CS|EA|LB)/i) && text.match(/\\d{5,}/) && allDivs[d].childElementCount > 2) {
                // Check it's a leaf-ish card, not a giant container
                if (text.length < 500) cardSet.push(allDivs[d]);
              }
            }
            cards = cardSet;
          }

          for (var i = 0; i < cards.length; i++) {
            try {
              var card = cards[i];
              var text = card.innerText || '';
              var lines = text.split('\\n').map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });

              // Extract SKU (7-digit number)
              var sku = null;
              for (var j = 0; j < lines.length; j++) {
                var skuMatch = lines[j].match(/^(\\d{6,8})$/);
                if (skuMatch) { sku = skuMatch[1]; break; }
              }
              if (!sku) {
                // Try finding SKU anywhere in text
                var anySkuMatch = text.match(/\\b(\\d{7})\\b/);
                if (anySkuMatch) sku = anySkuMatch[1];
              }
              if (!sku) continue;

              // Extract price: "$XX.XX CS" or "$XX.XXX LB"
              var priceMatch = text.match(/\\$(\\d+[,\\d]*\\.\\d{2,3})\\s*(CS|EA|LB|CW)/i);
              var price = priceMatch ? parseFloat(priceMatch[1].replace(',', '')) : null;
              var priceUnit = priceMatch ? priceMatch[2].toUpperCase() : null;

              // Extract brand + name + pack size
              // Brand line is usually "Sysco Classic" or "Tyson Red Label"
              // Name line follows with pack size appended: "Chicken Breast... 4/10 LB"
              var brand = '';
              var nameWithPack = '';
              var packSize = null;

              for (var j = 0; j < lines.length; j++) {
                // Brand is usually right before or after SKU
                if (lines[j].match(/^(Sysco|Tyson|Imperial|Buckhead|Arrezzio|Block|Jade Mountain)/i)) {
                  brand = lines[j];
                }
                // Name+pack is a line with pack size pattern at end
                var packMatch = lines[j].match(/(.+?)\\s+(\\d+\\/\\d+[#\\s]?\\w*|\\d+x\\d+\\s*\\w*|\\d+\\s*(LB|OZ|EA|CS|CT|GAL|#|lb|oz)\\b.*)$/i);
                if (packMatch && !lines[j].match(/^\\$/)) {
                  nameWithPack = packMatch[1];
                  packSize = packMatch[2];
                }
              }

              // Build supplier_name: brand + name
              var supplierName = brand;
              if (nameWithPack) {
                supplierName = (supplierName ? supplierName + ' ' : '') + nameWithPack;
              }
              if (!supplierName || supplierName.length < 3) {
                // Fallback: use all text lines except price/sku/button
                supplierName = lines.filter(function(l) {
                  return !l.match(/^\\$/) && !l.match(/^\\d{6,}$/) && !l.match(/Add to Cart/i) && !l.match(/DEAL FOR YOU/i);
                }).join(' ');
              }

              // If pack size not found, try extracting from name
              if (!packSize) {
                var anyPack = supplierName.match(/(\\d+\\/\\d+[#\\s]?\\w*|\\d+\\s*(LB|OZ|EA|CS|CT|#)\\b)/i);
                if (anyPack) packSize = anyPack[1];
              }

              products.push({
                supplier_sku: sku,
                supplier_name: supplierName.substring(0, 255),
                current_price: price,
                pack_size: packSize || null,
                price_unit: priceUnit || null,
                in_stock: !text.match(/out of stock|unavailable/i),
                supplier_url: 'https://shop.sysco.com/app/product/' + sku
              });
            } catch(e) {
              // Skip cards that fail to parse
            }
          }
          return products;
        })()
      JS
    rescue StandardError => e
      logger.error "[Sysco] Error extracting search products: #{e.message}"
      []
    end

    # ----------------------------------------------------------------
    # List scraping helpers
    # ----------------------------------------------------------------

    # Extract list names from the sidebar under "My Lists"
    def extract_list_sidebar
      browser.evaluate(<<~JS)
        (function() {
          var lists = [];
          var sidebar = document.body;

          // Find all clickable list items in the sidebar
          // "My Lists (N)" section contains user-created lists
          // "Sysco Lists (N)" section contains system lists (skip these)
          var allLinks = sidebar.querySelectorAll('a, [role="button"], [class*="list-item"], [class*="listItem"]');
          var inMyLists = false;
          var inSyscoLists = false;

          // First, try to find the section headers
          var allText = sidebar.querySelectorAll('*');
          for (var i = 0; i < allText.length; i++) {
            var el = allText[i];
            var text = (el.innerText || '').trim();

            // Detect "My Lists" section header
            if (text.match(/^My Lists/i) && el.childElementCount <= 2) {
              inMyLists = true;
              inSyscoLists = false;
              continue;
            }
            // Detect "Sysco Lists" section header — stop collecting
            if (text.match(/^Sysco Lists/i) && el.childElementCount <= 2) {
              inMyLists = false;
              inSyscoLists = true;
              continue;
            }

            // Skip "Create a New List" and section headers
            if (text.match(/Create.*List/i) || text.match(/^My Lists/i) || text.match(/^Sysco Lists/i)) continue;

            // Collect list names when we're in the "My Lists" section
            if (inMyLists && el.offsetHeight > 0 && text.length > 0 && text.length < 100) {
              // Make sure it's a leaf element (not a container)
              if (el.childElementCount === 0 || (el.childElementCount <= 2 && el.tagName !== 'DIV')) {
                // Check it's not already collected
                var alreadyHave = false;
                for (var j = 0; j < lists.length; j++) {
                  if (lists[j].name === text) { alreadyHave = true; break; }
                }
                if (!alreadyHave && !text.match(/^\\d+$/) && !text.match(/^My Lists/)) {
                  lists.push({ name: text, remote_id: text.toLowerCase().replace(/[^a-z0-9]+/g, '-') });
                }
              }
            }
          }

          return lists;
        })()
      JS
    rescue StandardError => e
      logger.error "[Sysco] Error extracting sidebar lists: #{e.message}"
      []
    end

    # Click a list name in the sidebar
    def click_sidebar_list(list_name)
      clicked = browser.evaluate(<<~JS)
        (function() {
          var els = document.querySelectorAll('a, span, div, [role="button"], [class*="list"]');
          for (var i = 0; i < els.length; i++) {
            var text = (els[i].innerText || '').trim();
            if (text === #{list_name.to_json} && els[i].offsetHeight > 0) {
              els[i].click();
              return true;
            }
          }
          return false;
        })()
      JS

      unless clicked
        logger.warn "[Sysco] Could not click list '#{list_name}' in sidebar"
      end
    end

    # Wait for the list items table to populate
    def wait_for_list_items(timeout: 10)
      timeout.times do
        has_items = browser.evaluate(<<~JS)
          (function() {
            // Check for table rows or item containers
            var rows = document.querySelectorAll('tr, [class*="list-item"], [class*="listItem"], [class*="item-row"]');
            // At least 1 data row (not just header)
            return rows.length > 1;
          })()
        JS
        return true if has_items

        # Check for "no items" message
        no_items = browser.evaluate(<<~JS)
          (function() {
            var text = document.body.innerText || '';
            return text.match(/no items|there are no items/i) ? true : false;
          })()
        JS
        return false if no_items

        sleep 1
      end
      false
    end

    # Extract items from the list detail table
    def extract_list_items
      items = browser.evaluate(<<~JS)
        (function() {
          var items = [];

          // The list table has columns: #, Item Details, Last Ordered, Order Qty, Price ($), Total ($)
          // Each item row shows:
          //   Name on first line
          //   "SKU | Pack Size | Brand" on second line
          //   Price like "$21.31 CS"

          // Try finding rows in a table
          var rows = document.querySelectorAll('tr');
          // Skip header row(s)
          var dataRows = [];
          for (var i = 0; i < rows.length; i++) {
            var text = (rows[i].innerText || '').trim();
            // Data rows contain a SKU (6-8 digit number) and usually a price
            if (text.match(/\\d{6,8}/) && !text.match(/^#.*Item Details/i)) {
              dataRows.push(rows[i]);
            }
          }

          // If no table rows, try card/div-based layout
          if (dataRows.length === 0) {
            var divs = document.querySelectorAll('[class*="item-row"], [class*="listItem"], [class*="list-row"]');
            for (var i = 0; i < divs.length; i++) {
              var text = (divs[i].innerText || '').trim();
              if (text.match(/\\d{6,8}/)) dataRows.push(divs[i]);
            }
          }

          for (var i = 0; i < dataRows.length; i++) {
            try {
              var row = dataRows[i];
              var text = row.innerText || '';
              var lines = text.split('\\n').map(function(l) { return l.trim(); }).filter(function(l) { return l.length > 0; });

              // Find the detail line: "8877383 | 1/50 LB | IMPERIAL FRESH"
              var sku = null;
              var packSize = null;
              var brand = null;

              for (var j = 0; j < lines.length; j++) {
                var detailMatch = lines[j].match(/(\\d{6,8})\\s*\\|\\s*([^|]+?)\\s*\\|\\s*(.+)/);
                if (detailMatch) {
                  sku = detailMatch[1];
                  packSize = detailMatch[2].trim();
                  brand = detailMatch[3].trim();
                  break;
                }
                // Sometimes just SKU without pipes
                var skuOnly = lines[j].match(/^(\\d{6,8})$/);
                if (skuOnly) sku = skuOnly[1];
              }

              if (!sku) continue;

              // Product name is usually the first meaningful line
              var name = '';
              for (var j = 0; j < lines.length; j++) {
                // Skip position number, checkbox text, SKU lines
                if (lines[j].match(/^\\d{1,3}$/) || lines[j].match(/^\\d{6,8}/) || lines[j].match(/^\\$/)) continue;
                if (lines[j].length > 5 && !lines[j].match(/^(CS|EA|LB|N\\/A|Sold and)/i)) {
                  name = lines[j];
                  break;
                }
              }

              // Extract price: "$21.31 CS" or "$14.050 LB"
              var priceMatch = text.match(/\\$(\\d+[,\\d]*\\.\\d{2,3})\\s*(CS|EA|LB|CW)/i);
              var price = priceMatch ? parseFloat(priceMatch[1].replace(',', '')) : null;
              var priceUnit = priceMatch ? priceMatch[2].toUpperCase() : null;

              // If there's a sale price (strikethrough original), take the lower one
              var allPrices = text.match(/\\$(\\d+[,\\d]*\\.\\d{2,3})/g);
              if (allPrices && allPrices.length > 1) {
                var prices = allPrices.map(function(p) { return parseFloat(p.replace('$', '').replace(',', '')); });
                price = Math.min.apply(null, prices);
              }

              // Extract order quantity from input
              var qtyInputs = row.querySelectorAll('input[type="number"], input[type="text"]');
              var qty = 0;
              for (var q = 0; q < qtyInputs.length; q++) {
                var val = parseFloat(qtyInputs[q].value);
                if (!isNaN(val)) { qty = val; break; }
              }

              items.push({
                sku: sku,
                name: name.substring(0, 255),
                price: price,
                pack_size: packSize || null,
                price_unit: priceUnit || null,
                quantity: qty,
                in_stock: !text.match(/out of stock|unavailable/i),
                position: i + 1
              });
            } catch(e) {
              // Skip rows that fail to parse
            }
          }
          return items;
        })()
      JS

      # Scroll down to check for more items not yet in viewport
      if items.is_a?(Array) && items.size > 0
        more_items = scroll_and_extract_remaining_items(items.size)
        items.concat(more_items) if more_items.any?
      end

      items || []
    rescue StandardError => e
      logger.error "[Sysco] Error extracting list items: #{e.message}"
      []
    end

    # Scroll down to load any additional list items
    def scroll_and_extract_remaining_items(already_have)
      all_new = []
      3.times do |scroll_attempt|
        browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
        sleep 2

        current_count = browser.evaluate(<<~JS)
          (function() {
            var rows = document.querySelectorAll('tr');
            var count = 0;
            for (var i = 0; i < rows.length; i++) {
              if ((rows[i].innerText || '').match(/\\d{6,8}/)) count++;
            }
            return count;
          })()
        JS

        break if current_count <= already_have + all_new.size
      end
      all_new
    end

    # ----------------------------------------------------------------
    # Login helpers
    # ----------------------------------------------------------------

    # Type text into a field using Ferrum's native CDP keyboard events.
    # This sends real browser-level keystrokes with small random delays
    # between characters, which satisfies bot detection that checks for
    # human-like typing patterns. JavaScript-dispatched events all fire
    # in a single frame and get flagged.
    def type_into_field(selectors, text)
      # Find the first visible field matching any selector
      sel = browser.evaluate(<<~JS)
        (function() {
          var selectors = #{selectors.to_json};
          for (var i = 0; i < selectors.length; i++) {
            var el = document.querySelector(selectors[i]);
            if (el && el.offsetHeight > 0) return selectors[i];
          }
          return null;
        })()
      JS
      return false unless sel

      # Click to focus the field
      node = browser.at_css(sel)
      node.click
      sleep 0.2

      # Clear any existing value
      browser.evaluate("document.querySelector('#{sel}').value = ''")
      browser.evaluate("document.querySelector('#{sel}').dispatchEvent(new Event('input', { bubbles: true }))")

      # Type each character with real CDP key events and human-like delays
      text.each_char do |char|
        browser.keyboard.type(char)
        sleep(rand(0.05..0.15)) # 50-150ms between keystrokes
      end

      # Final change event
      browser.evaluate("document.querySelector('#{sel}').dispatchEvent(new Event('change', { bubbles: true }))")
      true
    end

    # Fill the email/username field on the login page
    def fill_login_email
      # Try multiple selectors — Sysco may use various input patterns
      email_selectors = [
        'input[type="email"]',
        'input[name="email"]',
        'input[name="username"]',
        'input[name="loginfmt"]',        # Microsoft/Azure AD
        'input[name="identifier"]',
        'input#signInName',               # Azure AD B2C
        'input#signInName-facade',        # Azure AD B2C facade
        'input#i0116',                    # Microsoft login
        'input[autocomplete="username"]',
        'input[autocomplete="email"]'
      ]

      field = nil
      email_selectors.each do |sel|
        field = browser.at_css(sel) rescue nil
        if field
          logger.info "[Sysco] Found email field: #{sel}"
          break
        end
      end

      return false unless field

      # Use Ferrum's native keyboard typing — sends real Chrome DevTools
      # Protocol key events with natural timing. JavaScript-dispatched events
      # all fire in one frame which bot detection catches.
      type_into_field(email_selectors, credential.username)
    end

    # Fill the password field (appears dynamically after clicking Next)
    def fill_login_password
      password_selectors = [
        'input[type="password"]',
        'input[name="password"]',
        'input[name="passwd"]',           # Microsoft login
        'input#passwordInput',            # Azure AD B2C
        'input#i0118',                    # Microsoft login
        'input[autocomplete="current-password"]'
      ]

      # Wait for password field to appear (loaded via JS after email + Next)
      field = nil
      15.times do |attempt|
        password_selectors.each do |sel|
          candidate = browser.at_css(sel) rescue nil
          if candidate
            visible = browser.evaluate("(function() { var el = document.querySelector('#{sel}'); return el && el.offsetHeight > 0; })()")
            if visible
              field = candidate
              logger.info "[Sysco] Found password field: #{sel} (attempt #{attempt + 1})"
              break
            end
          end
        end
        break if field
        sleep 1
      end

      return false unless field

      # Use Ferrum's native keyboard typing (same as email field)
      type_into_field(password_selectors, credential.password)
    end

    # Click the "Next" button after entering email (advances to password step).
    # Waits for the button to become enabled — enterprise login forms often
    # keep it disabled until their JS validates the email field.
    def click_next_button
      clicked = false
      8.times do |attempt|
        clicked = browser.evaluate(<<~JS)
          (function() {
            // Try common "Next" button patterns
            var selectors = [
              "button#next",
              "button[type='submit']",
              "input[type='submit']",
              "button#idSIButton9"
            ];
            for (var i = 0; i < selectors.length; i++) {
              var btn = document.querySelector(selectors[i]);
              if (btn && btn.offsetHeight > 0 && !btn.disabled) { btn.click(); return true; }
            }

            // Fallback: find button by text content
            var buttons = document.querySelectorAll('button, input[type="submit"], a[role="button"]');
            for (var i = 0; i < buttons.length; i++) {
              var text = (buttons[i].innerText || buttons[i].value || '').trim().toLowerCase();
              if (['next', 'continue', 'sign in', 'log in'].includes(text) && !buttons[i].disabled) {
                buttons[i].click();
                return true;
              }
            }
            return false;
          })()
        JS
        break if clicked
        logger.info "[Sysco] Next button not yet enabled, waiting... (attempt #{attempt + 1}/8)"
        sleep 1
      end

      unless clicked
        logger.warn '[Sysco] Could not find Next button — trying Enter key on email field'
        browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('input[type="email"], input[type="text"]');
            for (var i = 0; i < inputs.length; i++) {
              if (inputs[i].offsetHeight > 0) {
                inputs[i].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
                inputs[i].dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', bubbles: true }));
                inputs[i].dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true }));
                return true;
              }
            }
            return false;
          })()
        JS
      end
    end

    # Click the login/submit button (after password is filled).
    # Waits for the button to become enabled, same as click_next_button.
    def click_login_submit
      clicked = false
      8.times do |attempt|
        clicked = browser.evaluate(<<~JS)
          (function() {
            // Try common submit button patterns
            var selectors = [
              "button[type='submit']",
              "input[type='submit']",
              "button#next",
              "button#idSIButton9",
              "button.btn-primary",
              "button[data-testid='submit']"
            ];
            for (var i = 0; i < selectors.length; i++) {
              var btn = document.querySelector(selectors[i]);
              if (btn && btn.offsetHeight > 0 && !btn.disabled) { btn.click(); return true; }
            }

            // Fallback: find button by text
            var buttons = document.querySelectorAll('button, input[type="submit"], a[role="button"]');
            for (var i = 0; i < buttons.length; i++) {
              var text = (buttons[i].innerText || buttons[i].value || '').trim().toLowerCase();
              if (['sign in', 'log in', 'login', 'submit', 'next', 'continue'].includes(text) && !buttons[i].disabled) {
                buttons[i].click();
                return true;
              }
            }
            return false;
          })()
        JS
        break if clicked
        logger.info "[Sysco] Submit button not yet enabled, waiting... (attempt #{attempt + 1}/8)"
        sleep 1
      end

      unless clicked
        logger.warn '[Sysco] Could not find enabled submit button — trying Enter key on password field'
        browser.evaluate(<<~JS)
          (function() {
            var el = document.querySelector('input[type="password"]');
            if (el) {
              el.dispatchEvent(new KeyboardEvent('keydown',  { key: 'Enter', code: 'Enter', bubbles: true }));
              el.dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', bubbles: true }));
              el.dispatchEvent(new KeyboardEvent('keyup',    { key: 'Enter', code: 'Enter', bubbles: true }));
            }
          })()
        JS
      end
    end

    # ----------------------------------------------------------------
    # MFA handling — optional, detected dynamically after password
    # ----------------------------------------------------------------

    def handle_mfa_if_prompted
      mfa_info = detect_mfa_prompt
      return false unless mfa_info

      logger.info "[Sysco] MFA detected: #{mfa_info[:type]} — #{mfa_info[:message]}"

      # Create a 2FA request for the user to submit their code
      tfa_request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        request_type: 'login',
        status: 'pending',
        prompt_message: mfa_info[:message],
        expires_at: 5.minutes.from_now
      )
      logger.info "[Sysco] Created 2FA request ##{tfa_request.id}, waiting for code..."
      credential.update!(two_fa_enabled: true, status: 'pending')

      # Broadcast via ActionCable so the global 2FA modal appears
      TwoFactorChannel.broadcast_to(
        credential.user,
        {
          type: 'two_fa_required',
          request_id: tfa_request.id,
          session_token: tfa_request.session_token,
          supplier_name: 'Sysco',
          two_fa_type: mfa_info[:type].to_s,
          prompt_message: mfa_info[:message],
          expires_at: tfa_request.expires_at.iso8601
        }
      )

      # Poll for user to enter the code via the web UI
      code = poll_for_2fa_code(tfa_request, timeout: 300)

      unless code
        tfa_request.update!(status: 'expired')
        raise AuthenticationError, 'Verification code was not entered in time'
      end

      # Enter the code
      logger.info '[Sysco] Entering MFA code...'
      enter_mfa_code(code)
      sleep 5

      # Verify success
      if detect_mfa_prompt
        tfa_request.update!(status: 'failed')
        raise AuthenticationError, 'MFA verification failed — still on code entry page'
      end

      # Check for error messages
      page_text = browser.evaluate('document.body?.innerText?.substring(0, 1000)') rescue ''
      if page_text.match?(/wrong.*code|incorrect.*code|invalid.*code/i)
        tfa_request.update!(status: 'failed')
        raise AuthenticationError, 'MFA verification failed: wrong code entered'
      end

      tfa_request.update!(status: 'verified')
      logger.info '[Sysco] MFA code accepted'
      true
    end

    # Detect if the current page is showing an MFA/verification code prompt
    def detect_mfa_prompt
      page_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 3000)')
      rescue StandardError
        ''
      end
      return nil if page_text.blank?

      # Check for common MFA keywords
      mfa_keywords = /verification\s*code|enter\s*(the\s*)?code|multi.?factor|one.?time\s*pass|mfa|two.?factor|security\s*code/i
      return nil unless page_text.match?(mfa_keywords)

      # Confirm there's actually a code input field visible
      has_code_input = browser.evaluate(<<~JS)
        (function() {
          // Look for code input fields (single field or multi-digit)
          var inputs = document.querySelectorAll('input[type="text"], input[type="tel"], input[type="number"]');
          for (var i = 0; i < inputs.length; i++) {
            var el = inputs[i];
            if (el.offsetHeight > 0) {
              var name = (el.name || '').toLowerCase();
              var id = (el.id || '').toLowerCase();
              var placeholder = (el.placeholder || '').toLowerCase();
              var label = (el.getAttribute('aria-label') || '').toLowerCase();
              if (name.match(/code|otp|token|verify|mfa/) ||
                  id.match(/code|otp|token|verify|mfa/) ||
                  placeholder.match(/code|enter|digit|verify/) ||
                  label.match(/code|verify|otp/) ||
                  el.maxLength == 1 || el.maxLength == 6) {
                return true;
              }
            }
          }
          return false;
        })()
      JS
      return nil unless has_code_input

      # Determine MFA type from page content
      mfa_type = if page_text.match?(/text.*message|sms|phone/i)
                   'sms'
                 elsif page_text.match?(/email|inbox/i)
                   'email'
                 else
                   'unknown'
                 end

      # Extract the prompt message
      message = if page_text.match?(/sent.*(?:to|at)\s+(\S+@\S+|\(\d{3}\)\s*\d{3}.?\d{4}|\d{3}.?\d{3}.?\d{4})/i)
                  "Sysco has sent a verification code. #{$&}"
                else
                  "Sysco requires a verification code. Please check your email or phone and enter the code."
                end

      { type: mfa_type, message: message }
    end

    # Enter an MFA code — handles both single-field and multi-digit-field patterns
    def enter_mfa_code(code)
      digits = code.to_s.gsub(/\D/, '').chars

      # Check for multi-field pattern (individual digit inputs like #code1-#code6)
      multi_field = browser.evaluate(<<~JS)
        (function() {
          // Check for numbered code fields
          for (var i = 1; i <= 8; i++) {
            var el = document.querySelector('#code' + i) ||
                     document.querySelector('[name="code' + i + '"]') ||
                     document.querySelector('[data-index="' + (i-1) + '"]');
            if (el && el.offsetHeight > 0) return 'multi';
          }
          // Check for a cluster of maxLength=1 inputs
          var singles = document.querySelectorAll('input[maxlength="1"]');
          if (singles.length >= 4) return 'single_char';
          return 'single_field';
        })()
      JS

      case multi_field
      when 'multi'
        # Individual digit fields (#code1, #code2, etc.)
        digits.each_with_index do |digit, i|
          browser.evaluate(<<~JS)
            (function() {
              var el = document.querySelector('#code#{i + 1}') ||
                       document.querySelector('[name="code#{i + 1}"]') ||
                       document.querySelector('[data-index="#{i}"]');
              if (!el) return;
              el.focus();
              var nativeSetter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
              ).set;
              nativeSetter.call(el, '#{digit}');
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            })()
          JS
          sleep 0.2
        end

      when 'single_char'
        # Multiple maxLength=1 inputs in sequence
        browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('input[maxlength="1"]');
            var digits = #{digits.to_json};
            for (var i = 0; i < Math.min(inputs.length, digits.length); i++) {
              inputs[i].focus();
              var nativeSetter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
              ).set;
              nativeSetter.call(inputs[i], digits[i]);
              inputs[i].dispatchEvent(new Event('input', { bubbles: true }));
              inputs[i].dispatchEvent(new Event('change', { bubbles: true }));
            }
          })()
        JS

      else
        # Single code field — enter the whole code at once
        full_code = digits.join
        browser.evaluate(<<~JS)
          (function() {
            var inputs = document.querySelectorAll('input[type="text"], input[type="tel"], input[type="number"]');
            for (var i = 0; i < inputs.length; i++) {
              var el = inputs[i];
              var name = (el.name || '').toLowerCase();
              var id = (el.id || '').toLowerCase();
              var placeholder = (el.placeholder || '').toLowerCase();
              if (el.offsetHeight > 0 && (
                  name.match(/code|otp|token|verify/) ||
                  id.match(/code|otp|token|verify/) ||
                  placeholder.match(/code|enter|digit|verify/) ||
                  el.maxLength == 6 || el.maxLength == 8)) {
                el.focus();
                var nativeSetter = Object.getOwnPropertyDescriptor(
                  window.HTMLInputElement.prototype, 'value'
                ).set;
                nativeSetter.call(el, #{full_code.to_json});
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
              }
            }
            return false;
          })()
        JS
      end

      # Try to submit the code form
      sleep 1
      browser.evaluate(<<~JS)
        (function() {
          var btns = document.querySelectorAll('button, input[type="submit"]');
          for (var i = 0; i < btns.length; i++) {
            var text = (btns[i].innerText || btns[i].value || '').trim().toLowerCase();
            if (['verify', 'submit', 'continue', 'confirm', 'next'].includes(text)) {
              btns[i].click();
              return true;
            }
          }
          // Fallback: click the first visible submit button
          var submit = document.querySelector("button[type='submit']");
          if (submit && submit.offsetHeight > 0) { submit.click(); return true; }
          return false;
        })()
      JS
    end

    # Poll for user-submitted 2FA code (same pattern as US Foods)
    def poll_for_2fa_code(tfa_request, timeout: 300)
      start_time = Time.current
      loop do
        tfa_request.reload
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

    # Detect login error messages on the page
    def detect_login_errors
      page_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 2000)')
      rescue StandardError
        ''
      end

      error_patterns = [
        /invalid.*(?:email|password|credentials)/i,
        /account.*(?:locked|disabled|suspended)/i,
        /incorrect.*password/i,
        /username.*not\s*found/i,
        /login.*failed/i,
        /access.*denied/i
      ]

      error_patterns.each do |pattern|
        if page_text.match?(pattern)
          raise AuthenticationError, "Login failed: #{page_text.match(pattern)[0]}"
        end
      end
    end

    # Wait for redirect to shop.sysco.com after successful auth
    def wait_for_post_login_redirect(timeout: 20)
      start_time = Time.current
      loop do
        current = begin
          browser.current_url
        rescue StandardError
          ''
        end
        return true if current.include?('shop.sysco.com')

        if Time.current - start_time > timeout
          logger.warn "[Sysco] Post-login redirect timed out (stuck at: #{current})"
          return false
        end

        sleep 1
      end
    end

    # ----------------------------------------------------------------
    # Stealth browser setup (adapted from US Foods)
    # ----------------------------------------------------------------

    def build_stealth_browser_opts
      ua = if ENV['BROWSER_PATH'].present? || Rails.env.production?
             'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
           else
             'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
           end

      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'

      opts = {
        headless: headless_mode ? 'new' : false,
        timeout: 60,
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
      opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?
      opts
    end

    def setup_network_interception(browser_instance)
      browser_instance.network.intercept
      browser_instance.on(:request) do |request|
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
      logger.warn "[Sysco] Network interception setup failed: #{e.message}"
    end

    def inject_stealth_scripts(browser_instance)
      stealth_js = <<~JS
        Object.defineProperty(navigator, 'webdriver', {get: () => false});
        Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
        Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
        if (!window.chrome) window.chrome = {};
        if (!window.chrome.runtime) window.chrome.runtime = {};
      JS
      browser_instance.evaluate_on_new_document(stealth_js)
    rescue StandardError => e
      logger.warn "[Sysco] CDP stealth injection failed: #{e.message}"
    end

    def apply_stealth
      browser.evaluate(<<~JS)
        (function() {
          Object.defineProperty(navigator, 'webdriver', {get: () => false});
          Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
          Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
          if (!window.chrome) window.chrome = {};
          if (!window.chrome.runtime) window.chrome.runtime = {};
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

    # ----------------------------------------------------------------
    # Session management (SPA — save cookies + localStorage + sessionStorage)
    # ----------------------------------------------------------------

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
      logger.info "[Sysco] Session saved (cookies: #{cookies.size}, localStorage: #{local_storage.size}, sessionStorage: #{session_storage.size})"
    end

    def restore_session
      return false unless credential.session_data.present?
      return false unless credential.session_valid?

      begin
        data = JSON.parse(credential.session_data)

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
          # Expected for SPA sites
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

        # Refresh so the SPA re-initializes with the restored auth tokens.
        # Without this, the page loaded before storage was injected and
        # the app thinks we're unauthenticated.
        logger.info "[Sysco] Session injected (cookies: #{cookies.size}, localStorage: #{local_storage.size}, sessionStorage: #{session_storage.size}) — refreshing..."
        browser.refresh
        sleep 3
        logger.info "[Sysco] Session restored, current URL: #{browser.current_url rescue 'unknown'}"
        true
      rescue JSON::ParserError => e
        logger.warn "[Sysco] Failed to parse session data: #{e.message}"
        false
      end
    end

    # ----------------------------------------------------------------
    # Diagnostics
    # ----------------------------------------------------------------

    def log_page_state(context)
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
      body_snippet = begin
        browser.evaluate('document.body?.innerText?.substring(0, 500)')
      rescue StandardError
        'could not read'
      end
      logger.info "[Sysco] #{context} — URL: #{current_url}, Title: #{page_title}"
      logger.debug "[Sysco] #{context} — Body: #{body_snippet}"
    end

    def diagnose_login_failure
      log_page_state('Login failure diagnosis')

      buttons = begin
        browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('button, a, input[type="submit"], [role="button"]');
            var info = [];
            for (var i = 0; i < els.length && i < 20; i++) {
              info.push(els[i].tagName + ':' + (els[i].innerText || els[i].value || '').trim().substring(0, 40));
            }
            return info.join(' | ');
          })()
        JS
      rescue StandardError
        'could not read'
      end
      logger.error "[Sysco] Visible buttons: #{buttons}"

      inputs = begin
        browser.evaluate(<<~JS)
          (function() {
            var els = document.querySelectorAll('input');
            var info = [];
            for (var i = 0; i < els.length && i < 20; i++) {
              var el = els[i];
              info.push(el.type + '#' + el.id + '.' + el.name + ' visible=' + (el.offsetHeight > 0));
            }
            return info.join(' | ');
          })()
        JS
      rescue StandardError
        'could not read'
      end
      logger.error "[Sysco] Visible inputs: #{inputs}"
    end
  end
end
