namespace :orders do
  desc "Test add-to-cart flow with visible browser (discovery mode)"
  task :test_add_to_cart, [:sku, :quantity] => :environment do |_t, args|
    sku = args[:sku]
    quantity = (args[:quantity] || 1).to_i

    unless sku
      puts "Usage: bin/rails orders:test_add_to_cart[SKU,QUANTITY]"
      puts "Example: bin/rails orders:test_add_to_cart[1234567,2]"
      puts "\nAvailable SKUs from US Foods:"
      SupplierProduct.joins(:supplier)
        .where(suppliers: { code: "usfoods" })
        .limit(10)
        .each do |sp|
          puts "  #{sp.supplier_sku} - #{sp.supplier_name} ($#{sp.current_price})"
        end
      exit 1
    end

    # Find US Foods credential
    supplier = Supplier.find_by(code: "usfoods")
    unless supplier
      puts "ERROR: US Foods supplier not found"
      exit 1
    end

    credential = SupplierCredential.find_by(supplier: supplier, status: "active")
    unless credential
      puts "ERROR: No active US Foods credential found"
      exit 1
    end

    puts "=" * 60
    puts "US Foods Add-to-Cart Test (Discovery Mode)"
    puts "=" * 60
    puts "SKU: #{sku}"
    puts "Quantity: #{quantity}"
    puts "Credential: #{credential.username}"
    puts "Browser: VISIBLE (non-headless)"
    puts "=" * 60

    # Run with visible browser
    ENV["BROWSER_HEADLESS"] = "false"

    scraper = Scrapers::UsFoodsScraper.new(credential)

    base_url = Scrapers::UsFoodsScraper::BASE_URL

    begin
      scraper.instance_eval do
        with_browser do
          puts "\n[1] Restoring session..."
          if restore_session
            puts "    Session cookies restored"
            navigate_to(Scrapers::UsFoodsScraper::BASE_URL)
            sleep 2

            if logged_in?
              puts "    ✓ Already logged in!"
            else
              puts "    Session invalid, performing login..."
              perform_login_steps
              save_session
            end
          else
            puts "    No session, performing login..."
            perform_login_steps
            save_session
          end

          puts "\n[2] Searching for product..."
          # Use the search bar to find the product
          search_input = browser.at_css("input.searchbar-input, ion-searchbar input, [placeholder*='Search']")
          if search_input
            puts "    Found search input, searching for SKU: #{sku}"
            search_input.focus
            search_input.type(sku, :clear)
            sleep 1
            # Press Enter to search
            browser.keyboard.type(:enter)
            sleep 3
          else
            puts "    No search input found, trying direct URL..."
            product_url = "#{Scrapers::UsFoodsScraper::BASE_URL}/desktop/product/#{sku}"
            puts "    URL: #{product_url}"
            navigate_to(product_url)
            sleep 3
          end

          puts "\n[3] Analyzing page structure..."
          puts "    Current URL: #{browser.current_url}"
          puts "    Page title: #{browser.evaluate('document.title')}"

          # Log all visible inputs
          puts "\n    Input elements found:"
          inputs = browser.evaluate(<<~JS)
            (function() {
              var inputs = document.querySelectorAll('input');
              var results = [];
              inputs.forEach(function(el) {
                var style = window.getComputedStyle(el);
                if (style.display !== 'none' && style.visibility !== 'hidden') {
                  results.push({
                    type: el.type,
                    name: el.name,
                    id: el.id,
                    class: el.className,
                    placeholder: el.placeholder,
                    value: el.value
                  });
                }
              });
              return results;
            })()
          JS
          inputs.each { |inp| puts "      - #{inp}" }

          # Log all buttons
          puts "\n    Button elements found:"
          buttons = browser.evaluate(<<~JS)
            (function() {
              var buttons = document.querySelectorAll('button, [role="button"], input[type="submit"]');
              var results = [];
              buttons.forEach(function(el) {
                var style = window.getComputedStyle(el);
                if (style.display !== 'none' && style.visibility !== 'hidden') {
                  results.push({
                    tag: el.tagName,
                    text: el.innerText?.substring(0, 50),
                    id: el.id,
                    class: el.className,
                    dataTestId: el.getAttribute('data-testid')
                  });
                }
              });
              return results;
            })()
          JS
          buttons.each { |btn| puts "      - #{btn}" }

          # Look for add to cart / order button
          puts "\n[4] Looking for add-to-cart elements..."
          add_selectors = [
            "[data-testid*='add']",
            "[data-testid*='cart']",
            "[data-testid*='order']",
            "button[class*='add']",
            "button[class*='cart']",
            "button[class*='order']",
            ".add-to-cart",
            ".add-to-order",
            "ion-button"
          ]

          add_selectors.each do |sel|
            elements = browser.css(sel)
            if elements.any?
              puts "    ✓ Found #{elements.count} elements matching: #{sel}"
              elements.each do |el|
                text = el.text.strip.truncate(40) rescue "?"
                puts "      Text: '#{text}'"
              end
            end
          end

          # Look for quantity input
          puts "\n[5] Looking for product cards and their structure..."

          # Try to find product cards/rows in search results
          product_info = browser.evaluate(<<~JS)
            (function() {
              // Look for product cards or rows
              var cards = document.querySelectorAll('[class*="product"], [class*="item"], [class*="card"], ion-card');
              var results = [];
              cards.forEach(function(card, idx) {
                if (idx > 5) return; // Limit to first 5
                var text = card.innerText?.substring(0, 200);
                var inputs = card.querySelectorAll('input');
                var buttons = card.querySelectorAll('ion-button, button');
                results.push({
                  class: card.className?.substring(0, 100),
                  textSnippet: text?.replace(/\\n/g, ' ')?.substring(0, 100),
                  inputCount: inputs.length,
                  buttonCount: buttons.length,
                  buttonTexts: Array.from(buttons).map(b => b.innerText?.trim()).slice(0, 3)
                });
              });
              return results;
            })()
          JS
          product_info.each { |info| puts "    Card: #{info}" }

          puts "\n[6] Looking for product rows with the target SKU..."

          # Find product rows and identify the one matching our SKU
          product_rows = browser.evaluate(<<~JS)
            (function() {
              // Look for elements containing the SKU
              var allText = document.body.innerText;
              var rows = document.querySelectorAll('ion-row, .product-row, [class*="search-result"], [class*="product-item"]');
              var results = [];

              // Also try to find by looking for the SKU text
              var elements = document.querySelectorAll('*');
              for (var el of elements) {
                if (el.innerText && el.innerText.includes('#{sku}') && el.querySelectorAll('ion-input').length > 0) {
                  var input = el.querySelector('ion-input input.native-input');
                  var addBtn = el.querySelector('ion-button');
                  results.push({
                    found: true,
                    tagName: el.tagName,
                    className: el.className?.substring(0, 80),
                    inputId: input?.id,
                    buttonText: addBtn?.innerText?.trim()
                  });
                  if (results.length >= 3) break;
                }
              }
              return results;
            })()
          JS
          puts "    Product rows containing SKU #{sku}:"
          product_rows.each { |row| puts "      #{row}" }

          puts "\n[7] Attempting to enter quantity using JavaScript..."

          # Use JavaScript to find the input for this specific product and set value
          result = browser.evaluate(<<~JS)
            (function() {
              // Find the product row containing our SKU
              var elements = document.querySelectorAll('*');
              for (var el of elements) {
                if (el.innerText && el.innerText.includes('#{sku}')) {
                  var ionInput = el.querySelector('ion-input');
                  if (ionInput) {
                    var nativeInput = ionInput.querySelector('input.native-input');
                    if (nativeInput) {
                      // Set value using Ionic's method if available
                      nativeInput.value = '#{quantity}';
                      nativeInput.dispatchEvent(new Event('input', { bubbles: true }));
                      nativeInput.dispatchEvent(new Event('change', { bubbles: true }));

                      // Also try setting on the ion-input component
                      ionInput.value = '#{quantity}';

                      return {
                        success: true,
                        inputId: nativeInput.id,
                        newValue: nativeInput.value
                      };
                    }
                  }
                }
              }
              return { success: false, message: 'Could not find input for SKU' };
            })()
          JS
          puts "    Result: #{result}"

          sleep 2

          puts "\n[8] Checking for Add to List/Order button near the product..."
          buttons_near_product = browser.evaluate(<<~JS)
            (function() {
              var elements = document.querySelectorAll('*');
              for (var el of elements) {
                if (el.innerText && el.innerText.includes('#{sku}')) {
                  var buttons = el.querySelectorAll('ion-button');
                  return Array.from(buttons).map(b => ({
                    text: b.innerText?.trim(),
                    class: b.className?.substring(0, 50)
                  }));
                }
              }
              return [];
            })()
          JS
          puts "    Buttons found:"
          buttons_near_product.each { |btn| puts "      - #{btn}" }

          puts "\n[8] Browser will stay open for 60 seconds for manual inspection..."
          puts "    Press Ctrl+C to exit early"

          sleep 60
        end
      end
    rescue Interrupt
      puts "\nInterrupted by user"
    rescue => e
      puts "\nERROR: #{e.class} - #{e.message}"
      puts e.backtrace.first(10).join("\n")
    end
  end

  desc "Test viewing the cart page"
  task test_cart: :environment do
    supplier = Supplier.find_by(code: "usfoods")
    credential = SupplierCredential.find_by(supplier: supplier, status: "active")

    unless credential
      puts "ERROR: No active US Foods credential found"
      exit 1
    end

    puts "=" * 60
    puts "US Foods Cart Page Test"
    puts "=" * 60

    ENV["BROWSER_HEADLESS"] = "false"
    scraper = Scrapers::UsFoodsScraper.new(credential)

    begin
      scraper.instance_eval do
        with_browser do
          puts "\n[1] Restoring session..."
          unless restore_session && (navigate_to(BASE_URL) || true) && logged_in?
            puts "    Performing login..."
            perform_login_steps
            save_session
          end
          puts "    ✓ Logged in"

          puts "\n[2] Looking for cart link/button..."
          cart_urls = [
            "#{BASE_URL}/cart",
            "#{BASE_URL}/desktop/cart",
            "#{BASE_URL}/order/cart"
          ]

          cart_urls.each do |url|
            puts "    Trying: #{url}"
            navigate_to(url)
            sleep 2

            if browser.current_url.include?("cart")
              puts "    ✓ Cart page loaded!"
              break
            end
          end

          puts "\n[3] Analyzing cart page structure..."
          puts "    Current URL: #{browser.current_url}"

          # Log cart-related elements
          puts "\n    Cart elements found:"
          cart_elements = browser.evaluate(<<~JS)
            (function() {
              var selectors = [
                '.cart', '[class*="cart"]', '[data-testid*="cart"]',
                '.order', '[class*="order"]',
                '.checkout', '[class*="checkout"]',
                '.subtotal', '.total'
              ];
              var results = [];
              selectors.forEach(function(sel) {
                var els = document.querySelectorAll(sel);
                els.forEach(function(el) {
                  if (el.innerText && el.innerText.length < 200) {
                    results.push({
                      selector: sel,
                      tag: el.tagName,
                      text: el.innerText.substring(0, 100)
                    });
                  }
                });
              });
              return results.slice(0, 20);
            })()
          JS
          cart_elements.each { |el| puts "      - #{el}" }

          puts "\n[4] Browser will stay open for 60 seconds..."
          sleep 60
        end
      end
    rescue Interrupt
      puts "\nInterrupted"
    rescue => e
      puts "\nERROR: #{e.message}"
    end
  end

  desc "Test full add-to-cart flow with US Foods list"
  task :test_add_to_list, [:sku, :quantity] => :environment do |_t, args|
    sku = args[:sku] || "3051265"
    quantity = (args[:quantity] || 1).to_i

    supplier = Supplier.find_by(code: "usfoods")
    credential = SupplierCredential.find_by(supplier: supplier, status: "active")

    unless credential
      puts "ERROR: No active US Foods credential found"
      exit 1
    end

    puts "=" * 60
    puts "US Foods Add-to-List Test"
    puts "=" * 60
    puts "SKU: #{sku}"
    puts "Quantity: #{quantity}"
    puts "Browser: VISIBLE"
    puts "=" * 60

    ENV["BROWSER_HEADLESS"] = "false"
    scraper = Scrapers::UsFoodsScraper.new(credential)

    begin
      result = scraper.add_to_cart([{ sku: sku, quantity: quantity }])
      puts "\n✓ Success!"
      puts "Result: #{result.inspect}"
    rescue => e
      puts "\n✗ Failed: #{e.class} - #{e.message}"
      puts e.backtrace.first(5).join("\n")
    end
  end

  desc "List recent orders and their status"
  task list: :environment do
    puts "Recent Orders:"
    puts "=" * 80

    Order.includes(:supplier, :user, :order_items)
      .order(created_at: :desc)
      .limit(20)
      .each do |order|
        status_color = case order.status
                       when "submitted" then "\e[32m" # green
                       when "failed" then "\e[31m"    # red
                       when "pending" then "\e[33m"   # yellow
                       else "\e[0m"
                       end

        puts "\n##{order.id} - #{order.supplier&.name || 'Unknown'}"
        puts "  Status: #{status_color}#{order.status}\e[0m"
        puts "  Items: #{order.order_items.count}"
        puts "  Total: $#{order.total_amount || 'N/A'}"
        puts "  Created: #{order.created_at.strftime('%Y-%m-%d %H:%M')}"
        puts "  Confirmation: #{order.confirmation_number}" if order.confirmation_number
        puts "  Error: #{order.error_message}" if order.error_message
      end
  end
end
