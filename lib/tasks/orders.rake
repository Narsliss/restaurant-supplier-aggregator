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

    begin
      scraper.instance_eval do
        with_browser do
          puts "\n[1] Restoring session..."
          if restore_session
            puts "    Session cookies restored"
            navigate_to(BASE_URL)
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

          puts "\n[2] Navigating to product page..."
          product_url = "#{BASE_URL}/desktop/product/#{sku}"
          puts "    URL: #{product_url}"
          navigate_to(product_url)
          sleep 3

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
          puts "\n[5] Looking for quantity input..."
          qty_selectors = [
            "input[type='number']",
            "input[name*='quantity']",
            "input[name*='qty']",
            "[data-testid*='quantity']",
            ".quantity-input",
            ".qty-input"
          ]

          qty_selectors.each do |sel|
            el = browser.at_css(sel)
            if el
              puts "    ✓ Found quantity input: #{sel}"
              puts "      Current value: #{el.value rescue '?'}"
            end
          end

          puts "\n[6] Browser will stay open for 60 seconds for manual inspection..."
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
