module Scrapers
  class ChefsWarehouseScraper < BaseScraper
    BASE_URL = 'https://www.chefswarehouse.com'.freeze
    ORDER_URL = 'https://order.chefswarehouse.com'.freeze
    ORDER_MINIMUM = 400.00
    # Checkout is controlled by supplier.checkout_enabled? (database flag)
    # No hardcoded gate — OrderPlacementService passes dry_run: true when checkout is disabled

    # Override with_browser to use longer timeout and stealth options
    # CW's Vue.js SPA needs more time and may trigger bot detection
    def with_browser
      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'

      browser_opts = {
        headless: headless_mode,
        timeout: 60,
        process_timeout: 30,
        window_size: [1920, 1080]
      }

      browser_opts[:browser_options] = {
        "no-sandbox": true,
        "disable-gpu": true,
        "disable-dev-shm-usage": true,
        "disable-blink-features": 'AutomationControlled'
      }

      # Allow custom Chrome/Chromium path via environment variable
      browser_opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?

      logger.info "[ChefsWarehouse] Starting browser (headless=#{headless_mode}, timeout=60)"
      @browser = Ferrum::Browser.new(**browser_opts)
      setup_network_interception(@browser)
      yield(browser)
    ensure
      browser&.quit
    end

    # Chef's Warehouse categories for catalog browsing
    # Categories are browsed via URL pattern: /shop/category-slug
    CW_CATEGORIES = %w[
      beef
      poultry
      pork
      seafood
      lamb-veal-game
      cheese
      dairy
      produce
      dry-goods
      beverages
      specialty-foods
      frozen
      equipment
      paper-goods
      cleaning-supplies
    ].freeze

    # ══════════════════════════════════════════════════════════════
    # API-based implementation — no browser needed
    # The methods below override BaseScraper's browser-based defaults.
    # Browser-based originals are preserved below as _browser_* methods.
    # ══════════════════════════════════════════════════════════════

    def api_client
      @api_client ||= ChefsWarehouseApi.new(credential)
    end

    # ── Auth ────────────────────────────────────────────────────

    def login
      logger.info '[ChefsWarehouse] API login'
      result = api_client.login
      if result
        credential.mark_active!
        logger.info '[ChefsWarehouse] API login succeeded'
      else
        raise AuthenticationError, 'CW API login failed'
      end
      result
    end

    def soft_refresh
      logger.info '[ChefsWarehouse] API soft refresh'
      if api_client.restore_session
        credential.mark_active!
        true
      else
        # CW uses password auth — we can always re-login via API
        logger.info '[ChefsWarehouse] Session expired, re-logging in via API'
        if api_client.login
          credential.mark_active!
          true
        else
          false
        end
      end
    rescue StandardError => e
      logger.warn "[ChefsWarehouse] API soft refresh error: #{e.message}"
      false
    end

    # ── Lists ───────────────────────────────────────────────────

    # Override BaseScraper#scrape_lists to bypass with_browser entirely.
    def scrape_lists
      api_client.ensure_session!

      guides = api_client.list_order_guides
      logger.info "[ChefsWarehouse] API found #{guides.size} order guides"

      result_lists = []
      guides.each do |guide|
        next if guide[:remote_id].blank?

        logger.info "[ChefsWarehouse] API fetching guide '#{guide[:name]}' (id=#{guide[:remote_id]})"
        data = api_client.fetch_order_guide(guide[:remote_id])
        next unless data

        # Fetch prices for all items in the guide
        products_with_prices = enrich_products_with_api_prices(data[:products])

        list_type = guide[:remote_id] == '-1' ? 'favorites' : 'order_guide'
        result_lists << {
          name: data[:name] || guide[:name],
          remote_id: guide[:remote_id],
          url: guide[:url],
          list_type: list_type,
          items: products_with_prices
        }
      end

      result_lists
    end

    # ── Prices ──────────────────────────────────────────────────

    def scrape_prices(product_skus)
      api_client.ensure_session!
      results = []

      # Build variant info for each SKU.
      # Variant codes follow the pattern JDE_{sku}-{businessUnitId}
      variants = product_skus.map do |sku|
        {
          code: "JDE_#{sku}-800001",
          uom: 'CS',
          stocking_type: 'P',
          vendor_id: nil,
          business_unit_id: '800001'
        }
      end

      prices = api_client.fetch_prices(variants)
      price_map = prices.index_by { |p| p[:variant_code] }

      # Also fetch piece prices for items sold by the piece.
      # The CS price for Piece items is the full-case price (e.g., $1,924
      # for 80 pieces) — we need the PC price ($23.82) instead.
      piece_skus = product_skus.select do |sku|
        sp = SupplierProduct.find_by(supplier: credential.supplier, supplier_sku: sku)
        sp&.pack_size.to_s.match?(/\bPiece\b/i)
      end

      piece_price_map = {}
      if piece_skus.any?
        piece_variants = piece_skus.map do |sku|
          {
            code: "JDE_#{sku}-800001",
            uom: 'PC',
            stocking_type: 'P',
            vendor_id: nil,
            business_unit_id: '800001'
          }
        end
        piece_prices = api_client.fetch_prices(piece_variants)
        piece_prices.each { |p| piece_price_map[p[:variant_code]] = p }
      end

      product_skus.each do |sku|
        variant_code = "JDE_#{sku}-800001"
        price_data = price_map[variant_code]
        next unless price_data

        sp = SupplierProduct.find_by(supplier: credential.supplier, supplier_sku: sku)

        # For Piece items, prefer the PC price over the inflated CS price
        current_price = price_data[:primary_price]
        if sp&.pack_size.to_s.match?(/\bPiece\b/i)
          piece_data = piece_price_map[variant_code]
          piece_price = piece_data&.dig(:secondary_price) || piece_data&.dig(:primary_price)
          current_price = piece_price if piece_price.present? && piece_price > 0
        end

        results << {
          supplier_sku: sku,
          current_price: current_price,
          in_stock: true,
          supplier_name: sp&.supplier_name || sp&.product&.name || sku
        }
      end

      results
    end

    # ── Catalog ─────────────────────────────────────────────────

    # API-based catalog import:
    #   1. Walk the category tree via API to discover all leaf categories
    #   2. Search each leaf category via the CMS search endpoint (paginated)
    #   3. Fetch prices in batches
    # No browser needed.
    def scrape_catalog(search_terms, max_per_term: 100, &on_batch)
      api_client.ensure_session!
      results = []

      # Discover all leaf categories
      logger.info '[ChefsWarehouse] API: Discovering leaf categories...'
      leaf_categories = discover_leaf_categories
      logger.info "[ChefsWarehouse] API: Found #{leaf_categories.size} leaf categories"

      leaf_categories.each do |category|
        begin
          category_products = []
          page_token = ''

          loop do
            search_result = api_client.search_category(
              category[:path],
              page_size: 50,
              page_token: page_token
            )
            batch = search_result[:products]
            break if batch.empty?

            formatted = batch.map { |p| format_catalog_product(p, category[:name]) }
            category_products.concat(formatted)

            if on_batch && formatted.any?
              on_batch.call(formatted)
            end

            # Check for next page
            page_token = search_result[:page_token].to_s
            break if page_token.blank?
            break if category_products.size >= max_per_term
          end

          results.concat(category_products) unless on_batch
          logger.info "[ChefsWarehouse] API category '#{category[:name]}': #{category_products.size} products"
        rescue StandardError => e
          logger.warn "[ChefsWarehouse] API category '#{category[:name]}' failed: #{e.class}: #{e.message}"
        end
      end

      return [] if on_batch

      deduped = results.uniq { |r| r[:supplier_sku] }
      logger.info "[ChefsWarehouse] API total unique products: #{deduped.size} (from #{results.size} raw)"
      deduped
    end

    # ── Cart & Checkout ─────────────────────────────────────────

    def add_to_cart(items, delivery_date: nil)
      api_client.ensure_session!

      # Look up variant metadata for each SKU from the order guide
      guide_data = load_order_guide_items
      added_items = []
      failed_items = []

      api_items = items.filter_map do |item|
        guide_item = guide_data[item[:sku]]
        unless guide_item
          logger.warn "[ChefsWarehouse] SKU #{item[:sku]} not found in order guide — skipping"
          failed_items << { sku: item[:sku], error: 'Not in order guide', name: item[:name] }
          next
        end

        {
          code: guide_item[:variant_code],
          metadata: guide_item[:variant_metadata],
          business_unit_id: guide_item[:business_unit_id] || '800001',
          quantity: item[:quantity] || 1,
          stocking_type: guide_item[:stocking_type],
          vendor_id: guide_item[:vendor_id],
          uom: item[:uom] || guide_item[:uom] || 'CS',
          sell_by_multiple: guide_item[:sell_by_multiple] || 1
        }
      end

      if api_items.any?
        begin
          result = api_client.add_to_cart(api_items)
          if result.is_a?(Hash) && result['success']
            added_items = items.select { |i| guide_data[i[:sku]] }
            logger.info "[ChefsWarehouse] API added #{result['totalCount']} items to cart"
          else
            logger.warn "[ChefsWarehouse] API add_to_cart returned: #{result.inspect[0..200]}"
            failed_items.concat(api_items.map { |i| { sku: i[:code], error: 'API rejected', name: nil } })
          end
        rescue StandardError => e
          logger.error "[ChefsWarehouse] API add_to_cart failed: #{e.message}"
          failed_items.concat(api_items.map { |i| { sku: i[:code], error: e.message, name: nil } })
        end
      end

      # Set delivery date if provided
      if delivery_date && added_items.any?
        begin
          api_client.set_delivery_date(delivery_date.to_s)
          logger.info "[ChefsWarehouse] API set delivery date: #{delivery_date}"
        rescue StandardError => e
          logger.warn "[ChefsWarehouse] API set_delivery_date failed: #{e.message}"
        end
      end

      if failed_items.any? && added_items.empty?
        raise ItemUnavailableError.new(
          "#{failed_items.count} item(s) could not be added",
          items: failed_items
        )
      end

      { added: added_items.count, failed: failed_items }
    end

    # Remove individual items from the cart by SKU.
    # Fetches the cart to find line item IDs, then removes each matching item.
    def remove_from_cart(skus)
      api_client.ensure_session!
      skus = Array(skus).map(&:to_s)

      cart = api_client.get_cart
      line_items = cart&.dig('items') || cart&.dig('lineItems') || []

      removed = []
      still_present = []

      skus.each do |sku|
        item = line_items.find { |li| (li['itemCode'] || li['sku']).to_s == sku }
        if item && item['id']
          api_client.remove_cart_item(item['id'])
          removed << sku
          logger.info "[ChefsWarehouse] Removed SKU #{sku} (line item #{item['id']})"
        else
          still_present << sku
          logger.warn "[ChefsWarehouse] SKU #{sku} not found in cart"
        end
      end

      { removed: removed, still_present: still_present }
    end

    def clear_cart
      api_client.ensure_session!
      api_client.delete_cart
      logger.info '[ChefsWarehouse] API cart cleared'
    rescue StandardError => e
      logger.warn "[ChefsWarehouse] API clear_cart failed: #{e.message}"
    end

    def checkout(dry_run: false)
      logger.info "[ChefsWarehouse] API checkout (dry_run=#{dry_run})"
      api_client.ensure_session!

      # Refresh prices
      api_client.refresh_cart_prices

      # Get cart data
      cart = api_client.get_cart
      unless cart.is_a?(Hash)
        raise ScrapingError, 'Could not retrieve cart'
      end

      item_count = cart.dig('summary', 'itemCount') || 0
      subtotal = cart.dig('summary', 'totals', 'totalDecimal') || 0.0

      raise ScrapingError, 'Cart is empty' if item_count == 0

      if subtotal < ORDER_MINIMUM
        raise OrderMinimumError.new(
          'Order minimum not met',
          minimum: ORDER_MINIMUM,
          current_total: subtotal
        )
      end

      delivery_address = cart.dig('summary', 'deliveryAddress')
      @last_delivery_address = delivery_address if delivery_address.present?

      if dry_run
        logger.info "[ChefsWarehouse] API DRY RUN COMPLETE — #{item_count} items, total=$#{subtotal}"
        return {
          confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
          total: subtotal,
          delivery_date: nil,
          dry_run: true,
          cart_items: [],
          checkout_summary: { item_count: item_count, subtotal: subtotal }
        }
      end

      # Validate before submitting
      validation = api_client.validate_cart
      logger.info "[ChefsWarehouse] API cart validation: #{validation.inspect}"

      # LIVE ORDER
      logger.warn "[ChefsWarehouse] API PLACING LIVE ORDER"
      result = api_client.submit_cart(dry_run: false)

      confirmation_number = result&.dig('confirmationNumber') || result&.dig('orderNumber') || "API-#{Time.current.strftime('%Y%m%d%H%M%S')}"
      logger.info "[ChefsWarehouse] API order placed: #{confirmation_number}"

      {
        confirmation_number: confirmation_number,
        total: subtotal,
        delivery_date: nil,
        dry_run: false,
        cart_items: [],
        checkout_summary: result
      }
    end

    def extract_delivery_address
      return @last_delivery_address if @last_delivery_address.present?

      cart = api_client.get_cart
      @last_delivery_address = cart&.dig('summary', 'deliveryAddress')
    rescue StandardError => e
      logger.warn "[ChefsWarehouse] API extract_delivery_address failed: #{e.message}"
      nil
    end

    private

    # ── API helpers ─────────────────────────────────────────────

    # Enrich order guide products with prices from the API.
    def enrich_products_with_api_prices(products)
      return products if products.empty?

      # Build variant list for price lookup
      variants = products.filter_map do |p|
        next unless p[:variant_code]
        {
          code: p[:variant_code],
          uom: p[:uom] || 'CS',
          stocking_type: p[:stocking_type] || 'P',
          vendor_id: p[:vendor_id],
          business_unit_id: p[:business_unit_id] || '800001'
        }
      end

      # Also fetch piece prices (secondary UOM)
      piece_variants = products.filter_map do |p|
        next unless p[:variant_code]
        {
          code: p[:variant_code],
          uom: 'PC',
          stocking_type: p[:stocking_type] || 'P',
          vendor_id: p[:vendor_id],
          business_unit_id: p[:business_unit_id] || '800001'
        }
      end

      prices = api_client.fetch_prices(variants)
      piece_prices = api_client.fetch_prices(piece_variants)

      # Build price lookup by variant code
      price_map = {}
      prices.each { |p| price_map[p[:variant_code]] = p }
      piece_price_map = {}
      piece_prices.each { |p| piece_price_map[p[:variant_code]] = p }

      products.map do |p|
        price_data = price_map[p[:variant_code]]
        piece_data = piece_price_map[p[:variant_code]]

        case_price = price_data&.dig(:primary_price)
        piece_price = piece_data&.dig(:secondary_price) || piece_data&.dig(:primary_price)

        # For items sold by the piece (pack_size contains "Piece"), the CS API
        # returns the full-case price (e.g., $1,924 for 80 pieces) but the order
        # guide lists them individually (e.g., "1x5 LB Piece"). Use the piece
        # price as the main price so the display matches what the chef actually pays.
        main_price = if p[:pack_size].to_s.match?(/\bPiece\b/i) && piece_price.present? && piece_price > 0
                       piece_price
                     else
                       case_price
                     end

        # Only store piece_price when it's a genuinely different price from the
        # case price — the CW API returns the same price for both UOMs when
        # piece ordering isn't actually available for a product.
        has_real_piece_price = piece_price.present? && piece_price > 0 &&
                               piece_price != case_price && piece_price != main_price

        {
          sku: p[:sku],
          name: p[:name],
          price: main_price,
          pack_size: p[:pack_size],
          quantity: 1,
          in_stock: p[:in_stock] != false,
          position: nil,
          price_unit: nil, # CW returns total selling price, not per-unit — don't trigger estimated_total multiplication
          piece_price: has_real_piece_price ? piece_price : nil,
          piece_pack_size: has_real_piece_price ? 'PC' : nil,
          remote_item_id: p[:variant_code]
        }
      end
    end

    def browser_opts_for_catalog
      headless_mode = ENV.fetch('BROWSER_HEADLESS', 'true') == 'true'
      opts = {
        headless: headless_mode,
        timeout: 60,
        process_timeout: 30,
        window_size: [1920, 1080],
        browser_options: {
          "no-sandbox": true,
          "disable-gpu": true,
          "disable-dev-shm-usage": true,
          "disable-blink-features": 'AutomationControlled'
        }
      }
      opts[:browser_path] = ENV['BROWSER_PATH'] if ENV['BROWSER_PATH'].present?
      opts
    end

    def format_catalog_product(product, category_name)
      {
        supplier_sku: product[:sku],
        supplier_name: product[:name],
        current_price: nil, # Prices fetched separately if needed
        pack_size: product[:pack_size],
        in_stock: product[:in_stock],
        category: category_name,
        subcategory: product[:subcategory],
        brand: product[:brand],
        supplier_url: "#{BASE_URL}/products/#{product[:sku]}/"
      }
    end

    # Fetch all order guide items and build a SKU -> variant data lookup.
    # Used by add_to_cart to get the metadata block needed for the cart/add API.
    def load_order_guide_items
      @order_guide_items_cache ||= begin
        guides = api_client.list_order_guides
        items = {}
        guides.each do |guide|
          next if guide[:remote_id].blank?
          data = api_client.fetch_order_guide(guide[:remote_id])
          next unless data
          data[:products].each do |p|
            items[p[:sku]] = p unless items[p[:sku]]
          end
        end
        items
      end
    end

    def derive_variant_code(sku)
      sp = SupplierProduct.find_by(supplier: credential.supplier, supplier_sku: sku)
      "JDE_#{sku}-800001"
    end

    # Walk the CW category tree via API to find all leaf categories.
    # Leaf = a category whose subcategories have no further children,
    # or a category with no subcategories at all.
    def discover_leaf_categories
      top_categories = api_client.fetch_categories
      leaves = []

      top_categories.each do |cat|
        walk_category(cat[:path], cat[:name], leaves)
      end

      leaves
    end

    def walk_category(path, name, leaves, depth: 0)
      return if depth > 5 # Safety limit

      response = api_client.fetch_category_page(path)
      return unless response.is_a?(Hash)

      vm = response['viewModel'] || {}

      # Top-level categories use 'subCategories' with name/url keys.
      # Subcategory pages use 'categoryLinks' with text/href keys (includes siblings).
      children = []

      sub_categories = vm['subCategories'] || []
      if sub_categories.any?
        # Top-level: subCategories are direct children
        children = sub_categories.map { |s| { 'href' => s['url'], 'text' => s['name'] } }
      else
        # Subcategory: categoryLinks includes siblings. Filter to children only.
        category_links = vm['categoryLinks'] || []
        children = category_links.select do |c|
          href = c['href'].to_s
          href != path && href.start_with?(path.chomp('/'))
        end
      end

      if children.empty?
        leaves << { path: path, name: name }
        logger.debug "[ChefsWarehouse] Leaf: #{name} (#{path})"
      else
        logger.debug "[ChefsWarehouse] Branch: #{name} -> #{children.size} children"
        children.each do |child|
          child_name = (child['text'] || child['name'])&.strip || name
          walk_category(child['href'], child_name, leaves, depth: depth + 1)
        end
      end
    rescue StandardError => e
      logger.warn "[ChefsWarehouse] Failed to walk category '#{name}' (#{path}): #{e.message}"
      leaves << { path: path, name: name }
    end

    # Navigate to a category page in the browser and scrape products from the DOM.
    # Handles pagination by clicking the Next button until all pages are scraped.
    def browse_category_page(category_path, category_name, max: 50)
      url = "#{BASE_URL}#{category_path}"
      navigate_to(url)
      sleep 4 # Wait for SPA + Algolia to load products

      all_products = []
      page = 1

      loop do
        # Scroll down to ensure all products on this page are rendered
        3.times do
          browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
          sleep 1
        end

        # Extract products from the current page
        page_products = extract_products_from_page(category_name)
        break if page_products.empty?

        all_products.concat(page_products)
        logger.debug "[ChefsWarehouse] Page #{page}: #{page_products.size} products (total: #{all_products.size})"

        break if all_products.size >= max

        # Try to click the Next page button
        has_next = browser.evaluate(<<~JS)
          (function() {
            // Look for next page button/link in pagination
            var nextBtns = document.querySelectorAll(
              '.ais-Pagination-item--nextPage a, ' +
              '.ais-Pagination-item--nextPage button, ' +
              'a[aria-label="Next"], ' +
              'button[aria-label="Next"], ' +
              '[class*="pagination"] [class*="next"] a, ' +
              '[class*="pagination"] [class*="next"] button'
            );
            for (var btn of nextBtns) {
              if (btn.offsetParent !== null && !btn.closest('[class*="disabled"]')) {
                btn.scrollIntoView({ block: 'center' });
                btn.click();
                return true;
              }
            }

            // Fallback: look for a ">" or "Next" text button in pagination
            var pagItems = document.querySelectorAll('[class*="pagination"] a, [class*="pagination"] button, [class*="Pagination"] a');
            for (var item of pagItems) {
              var text = (item.innerText || '').trim();
              if ((text === '›' || text === '>' || text === 'Next' || text === '»') && item.offsetParent !== null) {
                item.scrollIntoView({ block: 'center' });
                item.click();
                return true;
              }
            }

            return false;
          })()
        JS

        break unless has_next

        page += 1
        sleep 3 # Wait for next page to load
      end

      all_products.uniq { |p| p[:supplier_sku] }
    end

    # Extract products from the currently loaded page DOM.
    def extract_products_from_page(category_name)
      raw = browser.evaluate(<<~JS)
        (function() {
          var results = [];
          var seen = {};

          // CW PLP uses product cards/tiles
          var cards = document.querySelectorAll('.product-card, .product-tile, [class*="product-item"]');
          if (cards.length === 0) {
            cards = document.querySelectorAll('li.cw-list-item');
          }

          for (var i = 0; i < cards.length; i++) {
            var card = cards[i];

            var nameEl = card.querySelector('a.item-title, .item-title, .product-name, h3, h4, [class*="title"]');
            var name = nameEl ? nameEl.innerText.trim() : '';

            var sku = '';
            var prodLink = card.querySelector('a[href*="/products/"]');
            if (prodLink) {
              var hrefMatch = prodLink.getAttribute('href').match(/\\/products\\/([^/]+)\\/?$/);
              if (hrefMatch) sku = hrefMatch[1];
            }
            if (!sku) {
              var infoItems = card.querySelectorAll('ul.info-list li.item, .sku, [class*="sku"]');
              for (var j = 0; j < infoItems.length; j++) {
                var liText = infoItems[j].innerText.trim();
                if (liText.match(/^[A-Z0-9]{2,}$/i) && !liText.match(/^(CS|PC|EA)$/i)) {
                  sku = liText;
                  break;
                }
              }
            }

            if (!sku || !name || seen[sku]) continue;
            seen[sku] = true;

            var packEl = card.querySelector('.pack-size, [class*="pack"]');
            var packSize = packEl ? packEl.innerText.trim() : '';

            var priceEl = card.querySelector('.price, [class*="price"]');
            var price = null;
            if (priceEl) {
              var priceMatch = priceEl.innerText.trim().match(/\\$(\\d+[,\\d]*\\.\\d{2})/);
              if (priceMatch) price = parseFloat(priceMatch[1].replace(',', ''));
            }

            var brandEl = card.querySelector('.brand, .body-one, [class*="brand"]');
            var brand = brandEl ? brandEl.innerText.trim() : '';

            var oos = card.querySelector('.out-of-stock, .sold-out, [class*="out-of-stock"]');
            var inStock = !oos;

            results.push({
              sku: sku,
              name: name,
              price: price,
              packSize: packSize,
              brand: brand,
              inStock: inStock
            });
          }

          return JSON.stringify(results);
        })()
      JS

      products = begin
        JSON.parse(raw)
      rescue StandardError
        []
      end

      products.map do |p|
        {
          supplier_sku: p['sku'],
          supplier_name: p['name'],
          current_price: p['price'],
          pack_size: p['packSize'],
          in_stock: p['inStock'] != false,
          category: category_name,
          supplier_url: "#{BASE_URL}/products/#{p['sku']}/"
        }
      end
    end

    public

    # ══════════════════════════════════════════════════════════════
    # Browser-based code below (preserved for fallback)
    # ══════════════════════════════════════════════════════════════

    # Broad selectors — the site is a JS SPA with dynamically generated IDs
    # The login form uses type=text for email (not type=email) and has uid-* IDs
    EMAIL_SELECTORS = [
      '#email', '#username', '#loginEmail', '#userEmail',
      "input[name='email']", "input[name='username']", "input[name='loginId']",
      "input[type='email']",
      # CW uses dynamic uid-* IDs, so we need to find input by context
      "input[id^='uid-'][type='text']",
      "input[placeholder*='email' i]",
      "input[placeholder*='username' i]", "input[aria-label*='email' i]"
    ].freeze

    PASSWORD_SELECTORS = [
      '#password', '#loginPassword', '#userPassword',
      "input[name='password']", "input[type='password']",
      "input[id^='uid-'][type='password']",
      "input[placeholder*='password' i]", "input[aria-label*='password' i]"
    ].freeze

    SUBMIT_SELECTORS = [
      '.btn-sign-in',
      'button.btn-sign-in',
      "button[type='submit'].btn-secondary",
      '.login-btn', '.sign-in-button', '.btn-login', '.login-button',
      "button[data-testid*='login' i]", "button[data-testid*='sign' i]",
      # CW has multiple submit buttons - look for Sign In text
      "button[type='submit']"
    ].freeze

    LOGGED_IN_SELECTORS = [
      '.account-menu', '.user-nav', '.my-account-link', '.account-dropdown',
      '.user-menu', '.logged-in', '.user-greeting',
      "[data-testid='account']", "[data-testid='user-menu']",
      "a[href*='my-account']", "a[href*='dashboard']",
      "a[href*='logout']", "a[href*='sign-out']", "button[aria-label*='account' i]",
      '.header-account', '#account-menu', '#user-nav'
    ].freeze

    def browser_login
      with_browser do
        logger.info "[ChefsWarehouse] Starting browser login for #{credential.username}"

        # Determine the best login URL
        login_url = credential.supplier.login_url.presence || "#{BASE_URL}/login"
        logger.info "[ChefsWarehouse] Using login URL: #{login_url}"

        # Try restoring session first
        if restore_session
          navigate_to(BASE_URL)
          sleep 2 # Allow SPA to render
          if logged_in?
            logger.info '[ChefsWarehouse] Restored session successfully'
            return true
          end
          logger.info '[ChefsWarehouse] Session restore failed, proceeding with fresh login'
        end

        # Navigate to login page
        navigate_to(login_url)
        sleep 3 # Extra wait for SPA rendering
        logger.info "[ChefsWarehouse] On login page: #{browser.current_url}"

        # Check if we got redirected
        logger.info "[ChefsWarehouse] Redirected to: #{browser.current_url}" if browser.current_url != login_url

        # Use JavaScript to find and fill the login form
        # CW has multiple forms/inputs on the page, we need to find the login-specific ones
        # The login form has: text input (email), password input, and "Sign In" button
        login_result = browser.evaluate(<<~JS)
          (function() {
            var result = { found: false, email: null, password: null, button: null };

            // Find the password field first - there's usually only one
            var passwordInputs = document.querySelectorAll('input[type="password"]');
            var passwordField = null;
            for (var pw of passwordInputs) {
              if (pw.offsetParent !== null) {
                passwordField = pw;
                break;
              }
            }

            if (!passwordField) {
              return { found: false, error: 'No visible password field' };
            }

            // Find the email/username field - it's a text input near the password field
            // Look for text inputs that appear before the password field in DOM order
            var allInputs = document.querySelectorAll('input[type="text"], input[type="email"]');
            var emailField = null;

            // Strategy: find text input that's in the same form or container as password
            var passwordContainer = passwordField.closest('form') || passwordField.closest('div[class*="login"]') || passwordField.parentElement?.parentElement?.parentElement;

            if (passwordContainer) {
              var containerInputs = passwordContainer.querySelectorAll('input[type="text"], input[type="email"]');
              for (var inp of containerInputs) {
                if (inp.offsetParent !== null && inp !== passwordField) {
                  emailField = inp;
                  break;
                }
              }
            }

            // Fallback: just find the visible text input that comes before password
            if (!emailField) {
              for (var inp of allInputs) {
                if (inp.offsetParent !== null) {
                  emailField = inp;
                  break;
                }
              }
            }

            if (!emailField) {
              return { found: false, error: 'No visible email/text field' };
            }

            // Find the Sign In button - look for button with "Sign In" text near the form
            var submitButton = null;
            var buttons = document.querySelectorAll('button[type="submit"], button');
            for (var btn of buttons) {
              var text = (btn.innerText || '').trim().toLowerCase();
              if (text === 'sign in' && btn.offsetParent !== null) {
                submitButton = btn;
                break;
              }
            }

            // Store the element IDs or generate temp IDs for reference
            if (!emailField.id) emailField.id = 'cw-temp-email-' + Date.now();
            if (!passwordField.id) passwordField.id = 'cw-temp-password-' + Date.now();
            if (submitButton && !submitButton.id) submitButton.id = 'cw-temp-submit-' + Date.now();

            return {
              found: true,
              emailId: emailField.id,
              passwordId: passwordField.id,
              submitId: submitButton ? submitButton.id : null,
              emailType: emailField.type,
              debug: {
                emailPlaceholder: emailField.placeholder,
                containerClass: passwordContainer?.className?.substring(0, 50)
              }
            };
          })()
        JS

        unless login_result && login_result['found']
          dump = capture_page_diagnostics
          error_detail = login_result&.dig('error') || 'unknown'
          raise AuthenticationError, "Login form not found (#{error_detail}). #{dump}"
        end

        logger.info "[ChefsWarehouse] Found login form: email=##{login_result['emailId']}, password=##{login_result['passwordId']}, submit=##{login_result['submitId']}"

        # Fill credentials using Ferrum's native CDP keyboard input
        # Vue 3 v-model only responds to real keyboard events from Chrome DevTools Protocol,
        # not synthetic JS events or nativeSetter tricks
        email_id = login_result['emailId']
        password_id = login_result['passwordId']
        submit_id = login_result['submitId']

        # Get Ferrum element references via their discovered IDs
        email_el = browser.at_css("##{email_id}")
        password_el = browser.at_css("##{password_id}")

        raise AuthenticationError, 'Could not get element references for login fields' unless email_el && password_el

        # Fill email field using real keyboard input
        logger.info '[ChefsWarehouse] Typing username into email field'
        begin
          email_el.click
          sleep 0.2
          email_el.focus
          email_el.type(credential.username, :clear)
        rescue Ferrum::CoordinatesNotFoundError => e
          logger.debug "[ChefsWarehouse] Click failed for email, scrolling into view: #{e.message}"
          email_el.evaluate("this.scrollIntoView({ block: 'center' })")
          sleep 0.3
          email_el.click
          email_el.type(credential.username, :clear)
        end
        sleep 0.5

        # Fill password field using real keyboard input
        logger.info '[ChefsWarehouse] Typing password into password field'
        begin
          password_el.click
          sleep 0.2
          password_el.focus
          password_el.type(credential.password, :clear)
        rescue Ferrum::CoordinatesNotFoundError => e
          logger.debug "[ChefsWarehouse] Click failed for password, scrolling into view: #{e.message}"
          password_el.evaluate("this.scrollIntoView({ block: 'center' })")
          sleep 0.3
          password_el.click
          password_el.type(credential.password, :clear)
        end
        sleep 0.5

        logger.info '[ChefsWarehouse] Credentials entered, clicking submit'

        # Click submit button using Ferrum element click (real mouse event via CDP)
        if submit_id
          submit_el = browser.at_css("##{submit_id}")
          if submit_el
            begin
              submit_el.click
            rescue Ferrum::CoordinatesNotFoundError => e
              logger.debug "[ChefsWarehouse] Submit click failed, scrolling: #{e.message}"
              submit_el.evaluate("this.scrollIntoView({ block: 'center' })")
              sleep 0.3
              submit_el.click
            end
          else
            # Fallback: press Enter on password field
            browser.keyboard.type(:Enter)
          end
        else
          # No submit button found, press Enter
          browser.keyboard.type(:Enter)
        end

        sleep 2

        # If still on login page after click, try pressing Enter as fallback
        still_on_login = begin
          browser.current_url.to_s.include?('/login')
        rescue StandardError
          false
        end
        if still_on_login
          logger.info '[ChefsWarehouse] Still on login page after button click, trying Enter key'
          password_el_retry = begin
            browser.at_css("##{password_id}")
          rescue StandardError
            nil
          end
          if password_el_retry
            begin
              password_el_retry.focus
            rescue StandardError
              nil
            end
          end
          browser.keyboard.type(:Enter)
        end

        logger.info '[ChefsWarehouse] Form submitted, waiting for response...'
        wait_for_page_load
        sleep 5 # Extra wait for SPA navigation after login

        logger.info "[ChefsWarehouse] Post-login URL: #{browser.current_url}"

        # Check for login success — multiple strategies
        if logged_in?
          save_session
          credential.mark_active!
          logger.info '[ChefsWarehouse] Login successful'
          true
        elsif url_indicates_login_success?
          save_session
          credential.mark_active!
          logger.info '[ChefsWarehouse] Login successful (detected via URL change)'
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
        logger.debug '[ChefsWarehouse] Login/signup links found — not logged in'
        return false
      end

      # Check page text for logged-in indicators (exclude the login page itself)
      body_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 3000)')
      rescue StandardError
        ''
      end
      is_login_page = body_text.match?(/forgot password|create an account|sign in|stay signed in/i)
      return false if is_login_page

      # Positive signals from page text
      return true if body_text.match?(/my account|order guide|sign out|log ?out|my orders/i)

      false
    end

    def browser_scrape_prices(product_skus)
      results = []

      with_browser do
        # Restore session inline — do NOT call login() which has its own
        # with_browser block and would create a nested browser (killing ours).
        if restore_session
          navigate_to(BASE_URL)
          sleep 2
        end
        unless logged_in?
          perform_login_steps
          raise AuthenticationError, 'Could not log in for price verification' unless logged_in?
        end
        save_session

        product_skus.each do |sku|
          begin
            result = scrape_product(sku)
            results << result if result
          rescue ScrapingError => e
            logger.warn "[ChefsWarehouse] Failed to scrape SKU #{sku}: #{e.message}"
          end

          rate_limit_delay
        end

        # While browser is still open and authenticated, grab the delivery address
        begin
          extract_delivery_address
        rescue StandardError => e
          logger.warn "[ChefsWarehouse] Address extraction failed (non-fatal): #{e.message}"
        end
      end

      results
    end

    def browser_clear_cart
      with_browser do
        unless restore_session && logged_in?
          perform_login_steps
          save_session
        end

        navigate_to("#{BASE_URL}/cart")
        sleep 3

        # Check if cart has items
        cart_count = browser.evaluate(<<~JS)
          (function() {
            // Look for cart count in the shopping cart button (e.g. "10")
            var cartBtn = document.querySelector('.shopping-cart-btn, .mobile-shopping-cart-btn');
            if (cartBtn) {
              var num = parseInt(cartBtn.innerText.trim());
              if (!isNaN(num)) return num;
            }
            // Fallback: count quantity inputs on the cart page
            var inputs = document.querySelectorAll('input[type="number"]');
            return inputs.length;
          })()
        JS

        if cart_count.to_i == 0
          logger.info '[ChefsWarehouse] Cart is already empty'
          return
        end

        logger.info "[ChefsWarehouse] Clearing cart (#{cart_count} items)..."

        # Click the "Empty Cart" button
        clicked_empty = browser.evaluate(<<~JS)
          (function() {
            var buttons = document.querySelectorAll('button, a');
            for (var btn of buttons) {
              var text = (btn.innerText || '').trim().toLowerCase();
              if (text === 'empty cart' && btn.offsetParent !== null) {
                btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                btn.click();
                return true;
              }
            }
            return false;
          })()
        JS

        unless clicked_empty
          logger.warn '[ChefsWarehouse] Could not find Empty Cart button'
          return
        end

        sleep 1

        # CW shows a confirmation modal: "You're about to remove all items from your cart"
        # Confirm by clicking the second "Empty Cart" button in the modal
        confirmed = browser.evaluate(<<~JS)
          (function() {
            // Look for modal confirmation button — it's the "Empty Cart" button inside the modal
            var modal = document.querySelector('.modal, [class*="modal"], [role="dialog"]');
            if (modal) {
              var buttons = modal.querySelectorAll('button, a');
              for (var btn of buttons) {
                var text = (btn.innerText || '').trim().toLowerCase();
                if (text === 'empty cart') {
                  btn.click();
                  return { confirmed: true, method: 'modal-button' };
                }
              }
            }

            // Fallback: find all "Empty Cart" buttons and click the last one (modal confirm)
            var allBtns = document.querySelectorAll('button, a');
            var emptyBtns = [];
            for (var btn of allBtns) {
              var text = (btn.innerText || '').trim().toLowerCase();
              if (text === 'empty cart' && btn.offsetParent !== null) {
                emptyBtns.push(btn);
              }
            }
            if (emptyBtns.length > 1) {
              emptyBtns[emptyBtns.length - 1].click();
              return { confirmed: true, method: 'last-empty-btn' };
            }

            return { confirmed: false };
          })()
        JS

        if confirmed && confirmed['confirmed']
          logger.info "[ChefsWarehouse] Cart emptied (#{confirmed['method']})"
          sleep 2 # Wait for cart to clear
        else
          logger.warn '[ChefsWarehouse] Could not confirm Empty Cart modal'
        end
      end
    end

    def browser_add_to_cart(items, delivery_date: nil)
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
            logger.info "[ChefsWarehouse] Added SKU #{item[:sku]} (qty: #{item[:quantity]})"
          rescue StandardError => e
            logger.warn "[ChefsWarehouse] Failed to add SKU #{item[:sku]}: #{e.message}"
            failed_items << { sku: item[:sku], error: e.message, name: item[:name] }
          end

          rate_limit_delay
        end

        if failed_items.any?
          if added_items.empty?
            # ALL items failed — nothing in the cart, can't proceed
            raise ItemUnavailableError.new(
              "#{failed_items.count} item(s) could not be added",
              items: failed_items
            )
          else
            # Some items failed but others succeeded — log warning and continue
            logger.warn "[ChefsWarehouse] #{failed_items.count} item(s) skipped (unavailable): " \
                        "#{failed_items.map { |i| i[:sku] }.join(', ')}"
          end
        end

        { added: added_items.count, failed: failed_items }
      end
    end

    def browser_checkout(dry_run: false)
      logger.info "[ChefsWarehouse] browser checkout starting (dry_run=#{dry_run})"

      with_browser do
        # Step 1: Restore session / login
        unless restore_session && logged_in?
          perform_login_steps
          save_session
        end

        # Step 2: Navigate to cart page
        navigate_to_cart_page

        # Step 3: Extract cart data (JS-based DOM scanning)
        cart_data = extract_cart_data
        logger.info "[ChefsWarehouse] Cart: #{cart_data[:item_count]} items, subtotal=#{cart_data[:subtotal]}"

        # Step 4: Validate cart
        raise ScrapingError, 'Cart is empty' if cart_data[:item_count] == 0

        # Step 5: Check order minimum
        if cart_data[:subtotal] < ORDER_MINIMUM
          raise OrderMinimumError.new(
            'Order minimum not met',
            minimum: ORDER_MINIMUM,
            current_total: cart_data[:subtotal]
          )
        end

        # Step 6: Check for unavailable items
        if cart_data[:unavailable_items].any?
          raise ItemUnavailableError.new(
            "#{cart_data[:unavailable_items].count} item(s) are unavailable",
            items: cart_data[:unavailable_items]
          )
        end

        # Step 7: Navigate to checkout page
        proceed_to_checkout_page

        # Step 8: Extract checkout/review page data
        checkout_data = extract_checkout_data
        logger.info "[ChefsWarehouse] Checkout: total=#{checkout_data[:total]}, delivery=#{checkout_data[:delivery_date]}"

        # ═══════════════════════════════════════════
        # ═══ SAFETY GATE — DRY RUN CHECK ══════════
        # ═══════════════════════════════════════════
        if dry_run
          logger.info "[ChefsWarehouse] DRY RUN COMPLETE — stopping before final submit"
          logger.info "[ChefsWarehouse] Would have placed order: total=#{checkout_data[:total]}"

          return {
            confirmation_number: "DRY-RUN-#{Time.current.strftime('%Y%m%d%H%M%S')}",
            total: checkout_data[:total] || cart_data[:subtotal],
            delivery_date: checkout_data[:delivery_date],
            dry_run: true,
            cart_items: cart_data[:items],
            checkout_summary: checkout_data
          }
        end

        # Step 9: LIVE ORDER — Click final submit
        logger.warn "[ChefsWarehouse] PLACING LIVE ORDER — clicking submit"
        click_place_order_button

        # Step 10: Wait for confirmation
        confirmation = wait_for_order_confirmation

        logger.info "[ChefsWarehouse] Order placed: #{confirmation[:confirmation_number]}"
        confirmation
      end
    end

    # Extract delivery address from CW account page (browser-based fallback).
    # Must be called inside an existing with_browser block (browser already open).
    def browser_extract_delivery_address
      logger.info "[ChefsWarehouse] Extracting delivery address from account..."

      # Try the account dashboard addresses page
      address_urls = [
        "#{BASE_URL}/account-dashboard/addresses/",
        "#{BASE_URL}/account-dashboard/delivery-addresses/",
        "#{BASE_URL}/account-dashboard/"
      ]

      address_urls.each do |url|
        begin
          navigate_to(url)
          sleep 2

          # Log the page content for discovery
          page_text = browser.evaluate('document.body ? document.body.innerText : ""') rescue ''
          logger.info "[ChefsWarehouse] Address page (#{url}): #{page_text.first(1500)}"

          # Try to extract address via JavaScript - scan for address-like elements
          address = browser.evaluate(<<~JS)
            (function() {
              // Look for common address container patterns
              var selectors = [
                '[class*="address"]',
                '[class*="shipping"]',
                '[class*="delivery"]',
                '[data-address]',
                '[class*="location"]'
              ];

              for (var i = 0; i < selectors.length; i++) {
                var els = document.querySelectorAll(selectors[i]);
                for (var j = 0; j < els.length; j++) {
                  var text = els[j].innerText.trim();
                  // Look for text that contains a ZIP code pattern (basic address heuristic)
                  if (text && text.match(/\\b\\d{5}(-\\d{4})?\\b/) && text.length < 300) {
                    return text;
                  }
                }
              }

              // Fallback: scan all paragraphs and divs for address patterns
              var all = document.querySelectorAll('p, div, span, address');
              for (var k = 0; k < all.length; k++) {
                var t = all[k].innerText.trim();
                // Match: has a ZIP code, has a state abbreviation, reasonable length
                if (t && t.match(/\\b\\d{5}(-\\d{4})?\\b/) && t.match(/\\b[A-Z]{2}\\b/) && t.length > 10 && t.length < 300) {
                  // Avoid nav bars, footers, etc.
                  var parent = all[k].closest('nav, footer, header');
                  if (!parent) return t;
                }
              }

              return null;
            })()
          JS

          if address.present?
            # Clean up: collapse whitespace and newlines
            cleaned = address.gsub(/\s+/, ' ').strip
            logger.info "[ChefsWarehouse] Found delivery address: #{cleaned}"
            @last_delivery_address = cleaned
            return @last_delivery_address
          end
        rescue StandardError => e
          logger.warn "[ChefsWarehouse] Failed to extract address from #{url}: #{e.message}"
        end
      end

      logger.info "[ChefsWarehouse] Could not extract delivery address from any account page"
      @last_delivery_address = nil
    end

    private

    def add_single_item_to_cart(item)
      # Navigate directly to the product page - CW has predictable URLs
      product_url = "#{BASE_URL}/products/#{item[:sku]}/"
      navigate_to(product_url)
      sleep 3 # Wait for SPA to render

      # Check if we landed on a valid product page
      page_has_product = browser.evaluate(<<~JS)
        (function() {
          // Check for product detail indicators
          var hasProductName = !!document.querySelector('.product-name, .product-title, h1');
          var hasAddButton = !!document.querySelector('.add-to-cart-btn, button.add-to-cart');
          var hasPrice = document.body.innerText.match(/\\$\\d+\\.\\d{2}/);
          return hasProductName || hasAddButton || hasPrice;
        })()
      JS

      unless page_has_product
        # Fallback: try searching for the product
        logger.debug "[ChefsWarehouse] Direct product URL didn't work, trying search"
        encoded_sku = CGI.escape(item[:sku].to_s)
        navigate_to("#{BASE_URL}/search?q=#{encoded_sku}")
        sleep 3

        # Find and click the product link
        clicked = browser.evaluate(<<~JS)
          (function() {
            var links = document.querySelectorAll('a[href*="#{item[:sku]}"]');
            for (var link of links) {
              if (link.href.includes('/products/')) {
                link.click();
                return true;
              }
            }
            return false;
          })()
        JS

        raise ScrapingError, "Product not found for SKU #{item[:sku]}" unless clicked

        sleep 3

      end

      # Now we should be on the product detail page
      add_product_from_detail_page(item)
    end

    def add_product_from_detail_page(item)
      qty = item[:quantity].to_i
      qty = 1 if qty < 1

      # Select PC (Piece) UOM if requested — must happen before adding to cart
      if item[:uom] == "PC"
        select_piece_uom(item)
      end

      # CW's Vue.js SPA ignores programmatic quantity input changes.
      # Most reliable approach: click Add to Cart once per unit needed.
      qty.times do |i|
        clicked = browser.evaluate(<<~JS)
          (function() {
            // Phase 1: Scoped to product detail area (not recommendations)
            var pdpContainers = document.querySelectorAll(
              '.product-detail, .pdp-container, .product-info, [class*="product-detail"], [class*="pdp"], main > section:first-child, .product-page'
            );

            for (var container of pdpContainers) {
              var btn = container.querySelector('.add-to-cart-btn, button.add-to-cart, [class*="add-to-cart"]');
              if (btn && btn.offsetParent !== null) {
                btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                btn.click();
                return { clicked: true, selector: 'pdp-scoped', classes: btn.className };
              }
            }

            // Phase 2: First visible add-to-cart button
            var selectors = ['.add-to-cart-btn', 'button.add-to-cart', 'button[class*="add-to-cart"]'];
            for (var sel of selectors) {
              var buttons = document.querySelectorAll(sel);
              for (var btn of buttons) {
                if (btn.offsetParent !== null) {
                  btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                  btn.click();
                  return { clicked: true, selector: sel, classes: btn.className };
                }
              }
            }

            // Phase 3: Any button with "add to cart" text
            var allButtons = document.querySelectorAll('button');
            for (var btn of allButtons) {
              if (btn.innerText.toLowerCase().includes('add to cart')) {
                btn.scrollIntoView({ behavior: 'instant', block: 'center' });
                btn.click();
                return { clicked: true, method: 'text-match' };
              }
            }

            return { clicked: false };
          })()
        JS

        raise ScrapingError, "Add to cart button not found for SKU #{item[:sku]}" unless clicked && clicked['clicked']

        logger.debug "[ChefsWarehouse] Clicked add-to-cart (#{i + 1}/#{qty}): #{clicked.inspect}"
        wait_for_cart_confirmation

        # Brief pause between clicks to let Vue update the cart state
        sleep 1.5 if i < qty - 1
      end
    end

    # Click the PC (Piece) button on the product detail page before adding to cart.
    # CW shows CS/PC toggle buttons near the quantity input on items that support both.
    # Falls back to CS (default) with a warning if the PC button can't be found.
    def select_piece_uom(item)
      clicked = browser.evaluate(<<~JS)
        (function() {
          // Strategy 1: Look for buttons with data-uom or data-unit attributes
          var uomBtns = document.querySelectorAll('[data-uom], [data-unit], [data-value]');
          for (var btn of uomBtns) {
            var val = (btn.getAttribute('data-uom') || btn.getAttribute('data-unit') || btn.getAttribute('data-value') || '').toLowerCase();
            if (val === 'pc' || val === 'piece' || val === 'ea' || val === 'each') {
              btn.click();
              return { clicked: true, method: 'data-attr', value: val };
            }
          }

          // Strategy 2: Look for buttons/spans with text "PC" or "Piece" near the add-to-cart area
          var containers = document.querySelectorAll(
            '.product-detail, .pdp-container, .product-info, [class*="product-detail"], [class*="pdp"], main'
          );
          for (var container of containers) {
            var btns = container.querySelectorAll('button, span.selectable, a, [role="button"], label, input[type="radio"]');
            for (var btn of btns) {
              var text = btn.innerText ? btn.innerText.trim() : (btn.value || '');
              if (text.match(/^(PC|Piece|Each|EA)$/i)) {
                btn.click();
                return { clicked: true, method: 'text-match', text: text };
              }
            }
          }

          // Strategy 3: Look for radio inputs or select options
          var radios = document.querySelectorAll('input[type="radio"]');
          for (var radio of radios) {
            var label = document.querySelector('label[for="' + radio.id + '"]');
            var labelText = label ? label.innerText.trim() : '';
            if (labelText.match(/^(PC|Piece|Each|EA)$/i) || radio.value.match(/^(PC|Piece|Each|EA)$/i)) {
              radio.click();
              return { clicked: true, method: 'radio', value: radio.value };
            }
          }

          return { clicked: false };
        })()
      JS

      if clicked && clicked['clicked']
        logger.info "[ChefsWarehouse] Selected PC UOM for SKU #{item[:sku]}: #{clicked.inspect}"
        sleep 1.5 # Wait for Vue to re-render with piece pricing
      else
        logger.warn "[ChefsWarehouse] PC button not found for SKU #{item[:sku]} — proceeding with default UOM (CS)"
      end
    end

    def wait_for_cart_confirmation
      wait_for_any_selector(
        '.cart-notification',
        '.added-message',
        '.cart-popup',
        '.cart-updated',
        '.success-message',
        timeout: 5
      )
      sleep 1 # Brief pause before next item
    rescue ScrapingError
      # Check if cart count changed instead
      logger.debug '[ChefsWarehouse] No confirmation modal, checking cart state'
      sleep 1
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

    # Scrape order guides from Chef's Warehouse.
    # CW has an order guides page at /account-dashboard/order-guides/
    # which may contain one or more named order guides.
    def scrape_supplier_lists
      guides_url = "#{BASE_URL}/account-dashboard/order-guides/"
      logger.info "[ChefsWarehouse] Navigating to order guides: #{guides_url}"

      begin
        navigate_to(guides_url)
      rescue Ferrum::PendingConnectionsError
        logger.warn '[ChefsWarehouse] PendingConnectionsError on order guides page — continuing'
      end
      sleep 5

      # CW order guides page (Vue.js SPA) shows guide cards inside
      # section.order-guide-items containers. Each guide is an <a> tag
      # with class "cw-router-link" inside a div.guide-wrapper.
      #
      # Link hrefs:
      #   /account-dashboard/order-guides/detail/?id=-1         (Recently Purchased)
      #   /account-dashboard/order-guides/detail/?id=389493&type=user (user guide)
      #   /account-dashboard/order-guides/detail/?id=334597&type=csr  (CW-managed)
      #
      # Guide names in h5.item-title, item counts in li.item-count.
      guides_data = browser.evaluate(<<~JS)
        (function() {
          var guides = [];
          var seen = {};

          // Find guide links inside guide-wrapper containers
          var wrappers = document.querySelectorAll('.guide-wrapper');
          for (var i = 0; i < wrappers.length; i++) {
            var link = wrappers[i].querySelector('a[href*="order-guides/detail"]');
            if (!link) continue;

            var href = link.getAttribute('href') || '';
            var titleEl = wrappers[i].querySelector('.item-title, h5');
            var countEl = wrappers[i].querySelector('.item-count');

            var name = titleEl ? titleEl.innerText.trim() : '';
            var countMatch = countEl ? countEl.innerText.match(/(\\d+)/) : null;
            var itemCount = countMatch ? parseInt(countMatch[1]) : 0;

            // Extract guide ID from query parameter ?id=XXXXX
            var idMatch = href.match(/[?&]id=([^&]+)/);
            var guideId = idMatch ? idMatch[1] : null;

            if (name && guideId && !seen[guideId]) {
              seen[guideId] = true;
              guides.push({
                name: name.substring(0, 255),
                remote_id: guideId,
                url: href,
                item_count: itemCount
              });
            }
          }

          // Fallback: scan all links to order-guides/detail
          if (guides.length === 0) {
            var links = document.querySelectorAll('a[href*="order-guides/detail"]');
            for (var j = 0; j < links.length; j++) {
              var lhref = links[j].getAttribute('href') || '';
              var ltext = (links[j].innerText || '').trim().split('\\n')[0] || '';
              var lidMatch = lhref.match(/[?&]id=([^&]+)/);
              var lid = lidMatch ? lidMatch[1] : null;

              if (ltext && lid && !seen[lid]) {
                seen[lid] = true;
                guides.push({ name: ltext.substring(0, 255), remote_id: lid, url: lhref, item_count: 0 });
              }
            }
          }

          return JSON.stringify(guides);
        })()
      JS

      parsed_guides = begin
        JSON.parse(guides_data)
      rescue StandardError
        []
      end

      logger.info "[ChefsWarehouse] Found #{parsed_guides.size} order guides"

      # If no guides found, treat the current page as a single guide
      if parsed_guides.empty?
        products = extract_order_guide_products
        # Enrich with piece pricing while still on the guide page
        enrich_guide_items_with_piece_pricing(products)
        return [{
          name: 'Order Guide',
          remote_id: 'order-guide',
          url: guides_url,
          list_type: 'order_guide',
          items: products
        }]
      end

      # Scrape products from each guide
      result_lists = []
      parsed_guides.each do |guide|
        guide_name = guide['name']
        guide_url = guide['url']

        logger.info "[ChefsWarehouse] Scraping guide '#{guide_name}' (#{guide['item_count']} items expected)"

        if guide_url.present?
          full_url = guide_url.start_with?('http') ? guide_url : "#{BASE_URL}#{guide_url}"
          begin
            navigate_to(full_url)
          rescue Ferrum::PendingConnectionsError
            logger.warn "[ChefsWarehouse] PendingConnectionsError on guide '#{guide_name}' — continuing"
          end
          sleep 5
        end

        products = extract_order_guide_products
        logger.info "[ChefsWarehouse] Guide '#{guide_name}': #{products.size} products"

        # Enrich with piece pricing while still on the guide page —
        # clicks Piece variant buttons to read alternate prices
        enrich_guide_items_with_piece_pricing(products)

        # Determine list type based on guide ID
        list_type = guide['remote_id'] == '-1' ? 'favorites' : 'order_guide'

        result_lists << {
          name: guide_name,
          remote_id: guide['remote_id'],
          url: guide_url,
          list_type: list_type,
          items: products
        }

        rate_limit_delay
      end

      result_lists
    end

    # Enrich order guide items with piece pricing by clicking the Piece variant
    # button on items that have both Case and Piece UOM options.
    #
    # Must be called while the order guide detail page is still loaded in the browser.
    # For each item with a Piece variant, clicks Piece → reads new price → clicks Case back.
    #
    # Matches DOM elements to items by SKU (not position) because the DOM has
    # ~40 navigation li.cw-list-item elements before the actual products.
    def enrich_guide_items_with_piece_pricing(items)
      # Build a SKU lookup for the items array
      items_by_sku = {}
      items.each { |item| items_by_sku[item[:sku]] = item if item[:sku].present? }

      # Find DOM indices of items with both Case and Piece enabled, along with their SKU
      dual_uom_data = browser.evaluate(
        'Array.from(document.querySelectorAll("li.cw-list-item")).map(function(item, idx){' \
        'var btns=item.querySelectorAll(".variant-btn");' \
        'var hasCase=false,hasPiece=false;' \
        'Array.from(btns).forEach(function(b){' \
        'var t=b.innerText.trim();' \
        'if(t==="Case"&&!b.classList.contains("disabled"))hasCase=true;' \
        'if(t==="Piece"&&!b.classList.contains("disabled"))hasPiece=true});' \
        'if(!hasCase||!hasPiece)return null;' \
        'var link=item.querySelector("a[href*=products]");' \
        'var sku=null;' \
        'if(link){var m=link.getAttribute("href").match(/\\/products\\/([^/]+)/);if(m)sku=m[1]}' \
        'if(!sku){var infos=item.querySelectorAll("ul.info-list li.item");' \
        'for(var j=0;j<infos.length;j++){var t=infos[j].innerText.trim();if(t.match(/^[A-Z0-9]{2,}$/i)){sku=t;break}}}' \
        'return sku?idx+":"+sku:null' \
        '}).filter(function(v){return v!==null}).join(",")'
      )

      return if dual_uom_data.blank?

      # Parse "domIndex:sku" pairs
      pairs = dual_uom_data.split(',').map { |s| idx, sku = s.split(':', 2); [idx.to_i, sku] }
      logger.info "[ChefsWarehouse] Found #{pairs.size} items with Case/Piece toggle on order guide"

      enriched = 0
      pairs.each do |dom_idx, sku|
        item = items_by_sku[sku]
        next unless item # SKU not in our extracted items

        begin
          # Click the Piece button on this DOM element
          clicked = browser.evaluate(
            "Array.from(document.querySelectorAll('li.cw-list-item')[#{dom_idx}]" \
            ".querySelectorAll('.variant-btn')).filter(function(b){" \
            "return b.innerText.trim()==='Piece'&&!b.classList.contains('disabled')" \
            "}).map(function(b){b.click();return true})[0]||false"
          )
          next unless clicked

          sleep 1.5 # Wait for Vue re-render

          # Read the piece price from the DOM element's price span
          piece_price_str = browser.evaluate(
            "document.querySelectorAll('li.cw-list-item')[#{dom_idx}]" \
            ".querySelector('span.price')" \
            "?document.querySelectorAll('li.cw-list-item')[#{dom_idx}]" \
            ".querySelector('span.price').innerText.trim():''"
          )

          # Read the piece pack size
          piece_pack = browser.evaluate(
            "document.querySelectorAll('li.cw-list-item')[#{dom_idx}]" \
            ".querySelector('.pack-size,[class*=pack]')" \
            "?document.querySelectorAll('li.cw-list-item')[#{dom_idx}]" \
            ".querySelector('.pack-size,[class*=pack]').innerText.trim():''"
          )

          # Click back to Case
          browser.evaluate(
            "Array.from(document.querySelectorAll('li.cw-list-item')[#{dom_idx}]" \
            ".querySelectorAll('.variant-btn')).filter(function(b){" \
            "return b.innerText.trim()==='Case'&&!b.classList.contains('disabled')" \
            "}).map(function(b){b.click();return true})[0]||false"
          )
          sleep 0.5

          # Parse and validate piece price
          next unless piece_price_str.present?

          price_match = piece_price_str.match(/\$(\d+[,\d]*\.\d{2})/)
          next unless price_match

          piece_price = price_match[1].delete(',').to_f
          next unless piece_price > 0 && piece_price != item[:price]

          item[:piece_price] = piece_price
          item[:piece_pack_size] = piece_pack.presence
          enriched += 1
          logger.info "[ChefsWarehouse] Piece price $#{piece_price} for #{item[:name]} (SKU: #{sku}, case: $#{item[:price]})"
        rescue StandardError => e
          logger.debug "[ChefsWarehouse] Error reading piece price for #{sku} (DOM #{dom_idx}): #{e.message}"
          browser.evaluate(
            "Array.from(document.querySelectorAll('li.cw-list-item')[#{dom_idx}]" \
            ".querySelectorAll('.variant-btn')).filter(function(b){" \
            "return b.innerText.trim()==='Case'}).map(function(b){b.click();return true})[0]||false"
          ) rescue nil
        end
      end

      logger.info "[ChefsWarehouse] Piece price enrichment complete: #{enriched}/#{pairs.size} items enriched"
    end

    # Extract products from the current order guide detail page.
    #
    # CW guide detail pages (Vue.js SPA) show products as li.cw-list-item
    # elements inside div.order-guide-detail-items. Each item has:
    #   - Name in a.item-title
    #   - SKU in ul.info-list > li.item (second li, after brand)
    #   - Brand in ul.info-list > li.item.body-one > a
    #   - Pack size in span.pack-size
    #   - Price in span.price
    def extract_order_guide_products
      # Scroll to load all products (CW lazy-loads on scroll)
      last_count = 0
      10.times do
        browser.evaluate('window.scrollTo(0, document.body.scrollHeight)')
        sleep 2
        current_count = browser.evaluate("document.querySelectorAll('li.cw-list-item').length") rescue 0
        break if current_count == last_count && current_count > 0
        last_count = current_count
      end

      # Extract from guide detail list items
      raw = begin
        browser.evaluate(<<~JS)
          (function() {
            var results = [];
            var seen = {};
            var items = document.querySelectorAll('li.cw-list-item');

            for (var i = 0; i < items.length; i++) {
              var item = items[i];

              // Name from the item-title link
              var nameEl = item.querySelector('a.item-title, .item-title');
              var name = nameEl ? nameEl.innerText.trim() : '';

              // SKU: second <li> in the info-list (first is brand)
              var infoItems = item.querySelectorAll('ul.info-list li.item');
              var sku = '';
              var brand = '';
              for (var j = 0; j < infoItems.length; j++) {
                var liText = infoItems[j].innerText.trim();
                if (infoItems[j].classList.contains('body-one')) {
                  brand = liText;
                } else if (liText.match(/^[A-Z0-9]{2,}$/i)) {
                  sku = liText;
                }
              }

              // Also try extracting SKU from product link href (/products/SKU/)
              if (!sku) {
                var prodLink = item.querySelector('a[href*="/products/"]');
                if (prodLink) {
                  var hrefMatch = prodLink.getAttribute('href').match(/\\/products\\/([^/]+)/);
                  if (hrefMatch) sku = hrefMatch[1];
                }
              }

              if (!sku || !name || seen[sku]) continue;
              seen[sku] = true;

              // Pack size
              var packEl = item.querySelector('.pack-size');
              var packSize = packEl ? packEl.innerText.trim() : '';

              // Price (e.g. "$60.50 / Piece" or "$129.15 / Case")
              var priceEl = item.querySelector('.price');
              var price = null;
              var priceUomLabel = null;
              if (priceEl) {
                var priceText = priceEl.innerText.trim();
                var priceMatch = priceText.match(/\\$(\\d+[,\\d]*\\.\\d{2})/);
                if (priceMatch) price = parseFloat(priceMatch[1].replace(',', ''));
                // Capture UOM from "/ Piece" or "/ Case" suffix
                var uomMatch = priceText.match(/\\/\\s*(Piece|Case|Each|PC|CS)/i);
                if (uomMatch) priceUomLabel = uomMatch[1].toLowerCase();
              }

              // Look for CS/PC toggle or alternate price within the item
              // CW may show toggle buttons, a secondary price, or data attributes
              var piecePrice = null;
              var piecePack = null;
              var casePrice = null;

              // Strategy 1: Look for UOM toggle buttons with price data
              var uomBtns = item.querySelectorAll('[data-uom], [data-unit], .uom-toggle button, .unit-toggle button, .uom-selector button');
              for (var b = 0; b < uomBtns.length; b++) {
                var btn = uomBtns[b];
                var btnText = btn.innerText.trim().toLowerCase();
                var btnPrice = btn.getAttribute('data-price') || btn.getAttribute('data-unit-price');
                if (btnPrice) {
                  var parsedBtnPrice = parseFloat(btnPrice.replace(/[^\\d.]/g, ''));
                  if (btnText.match(/piece|pc|ea/i)) {
                    piecePrice = parsedBtnPrice;
                  } else if (btnText.match(/case|cs/i)) {
                    casePrice = parsedBtnPrice;
                  }
                }
              }

              // Strategy 2: Look for secondary price elements
              var priceEls = item.querySelectorAll('.price, [class*="price"]');
              for (var p = 0; p < priceEls.length; p++) {
                var pEl = priceEls[p];
                var pText = pEl.innerText.trim();
                var pMatch = pText.match(/\\$(\\d+[,\\d]*\\.\\d{2})/);
                var pUom = pText.match(/\\/\\s*(Piece|Case|Each|PC|CS)/i);
                if (pMatch && pUom) {
                  var pVal = parseFloat(pMatch[1].replace(',', ''));
                  if (pUom[1].toLowerCase().match(/piece|pc|ea/) && pVal !== price) {
                    piecePrice = pVal;
                  } else if (pUom[1].toLowerCase().match(/case|cs/) && pVal !== price) {
                    casePrice = pVal;
                  }
                }
              }

              // Assign piece/case prices based on the primary price UOM
              if (priceUomLabel && priceUomLabel.match(/piece|pc|ea/)) {
                // Primary price IS the piece price
                piecePrice = piecePrice || price;
                price = casePrice || price; // prefer case as the main price
                // If we only have piece price, keep it as primary and set piecePrice
                if (!casePrice) {
                  price = piecePrice;
                  piecePrice = null; // only one UOM available
                }
              } else if (piecePrice && !casePrice) {
                // Primary is case, we found a piece price — good
              }

              // Full name with brand
              var fullName = brand ? (name + ' - ' + brand) : name;

              // In stock (check for out-of-stock indicators)
              var outOfStock = item.querySelector('.out-of-stock, [class*="out-of-stock"]');
              var inStock = !outOfStock && !item.innerText.match(/out of stock/i);

              results.push({
                sku: sku,
                name: fullName.substring(0, 255),
                price: price,
                piece_price: piecePrice,
                piece_pack_size: piecePack,
                pack_size: packSize,
                in_stock: inStock,
                price_uom_label: priceUomLabel
              });
            }

            return results;
          })()
        JS
      rescue StandardError
        []
      end

      (raw || []).each_with_index.map do |item, idx|
        {
          sku: item['sku'],
          name: item['name'],
          price: item['price'].is_a?(Numeric) ? item['price'] : nil,
          piece_price: item['piece_price'].is_a?(Numeric) ? item['piece_price'] : nil,
          piece_pack_size: item['piece_pack_size'].to_s.strip.presence,
          pack_size: item['pack_size'].to_s.strip.presence,
          quantity: 1,
          in_stock: item['in_stock'] != false,
          position: idx + 1
        }
      end
    end

    protected

    # Robust login flow using JS-based form discovery.
    # Reuses the same approach as the main login() method but without the
    # with_browser wrapper so it can be called from scrape_prices/add_to_cart
    # which already have an open browser session.
    def perform_login_steps
      login_url = credential.supplier.login_url.presence || "#{BASE_URL}/login"
      navigate_to(login_url)
      sleep 3

      logger.info "[ChefsWarehouse] perform_login_steps: on #{browser.current_url}"

      # Use JavaScript to discover the login form — same approach as login()
      login_result = browser.evaluate(<<~JS)
        (function() {
          var result = { found: false, email: null, password: null, button: null };

          var passwordInputs = document.querySelectorAll('input[type="password"]');
          var passwordField = null;
          for (var pw of passwordInputs) {
            if (pw.offsetParent !== null) { passwordField = pw; break; }
          }
          if (!passwordField) return { found: false, error: 'No visible password field' };

          var passwordContainer = passwordField.closest('form') || passwordField.closest('div[class*="login"]') || passwordField.parentElement?.parentElement?.parentElement;
          var emailField = null;

          if (passwordContainer) {
            var containerInputs = passwordContainer.querySelectorAll('input[type="text"], input[type="email"]');
            for (var inp of containerInputs) {
              if (inp.offsetParent !== null && inp !== passwordField) { emailField = inp; break; }
            }
          }
          if (!emailField) {
            var allInputs = document.querySelectorAll('input[type="text"], input[type="email"]');
            for (var inp of allInputs) {
              if (inp.offsetParent !== null) { emailField = inp; break; }
            }
          }
          if (!emailField) return { found: false, error: 'No visible email/text field' };

          var submitButton = null;
          var buttons = document.querySelectorAll('button[type="submit"], button');
          for (var btn of buttons) {
            var text = (btn.innerText || '').trim().toLowerCase();
            if (text === 'sign in' && btn.offsetParent !== null) { submitButton = btn; break; }
          }

          if (!emailField.id) emailField.id = 'cw-temp-email-' + Date.now();
          if (!passwordField.id) passwordField.id = 'cw-temp-password-' + Date.now();
          if (submitButton && !submitButton.id) submitButton.id = 'cw-temp-submit-' + Date.now();

          return {
            found: true,
            emailId: emailField.id,
            passwordId: passwordField.id,
            submitId: submitButton ? submitButton.id : null
          };
        })()
      JS

      unless login_result && login_result['found']
        error_detail = login_result&.dig('error') || 'unknown'
        logger.error "[ChefsWarehouse] perform_login_steps: form not found (#{error_detail})"
        # Fall back to basic selector approach
        email_field = discover_field(EMAIL_SELECTORS, 'email/username')
        password_field = discover_field(PASSWORD_SELECTORS, 'password')
        if email_field && password_field
          fill_element(email_field, credential.username, 'email')
          fill_element(password_field, credential.password, 'password')
          check_remember_me
          submit_btn = discover_field(SUBMIT_SELECTORS, 'submit button')
          if submit_btn
            begin; submit_btn.click; rescue StandardError; submit_btn.evaluate('this.click()'); end
          else
            browser.keyboard.type(:Enter)
          end
          wait_for_page_load
          sleep 3
        end
        return
      end

      logger.info "[ChefsWarehouse] perform_login_steps: found form — email=##{login_result['emailId']}, submit=##{login_result['submitId']}"

      # Fill using real CDP keyboard input (required for Vue.js v-model)
      email_el = browser.at_css("##{login_result['emailId']}")
      password_el = browser.at_css("##{login_result['passwordId']}")

      unless email_el && password_el
        logger.error "[ChefsWarehouse] perform_login_steps: could not get element references"
        return
      end

      begin
        email_el.click; sleep 0.2; email_el.focus
        email_el.type(credential.username, :clear)
      rescue Ferrum::CoordinatesNotFoundError
        email_el.evaluate("this.scrollIntoView({ block: 'center' })")
        sleep 0.3; email_el.click
        email_el.type(credential.username, :clear)
      end
      sleep 0.5

      begin
        password_el.click; sleep 0.2; password_el.focus
        password_el.type(credential.password, :clear)
      rescue Ferrum::CoordinatesNotFoundError
        password_el.evaluate("this.scrollIntoView({ block: 'center' })")
        sleep 0.3; password_el.click
        password_el.type(credential.password, :clear)
      end
      sleep 0.5

      # Check "remember me" / "stay signed in" if present
      check_remember_me

      # Click submit
      if login_result['submitId']
        submit_el = browser.at_css("##{login_result['submitId']}")
        if submit_el
          begin
            submit_el.click
          rescue Ferrum::CoordinatesNotFoundError
            submit_el.evaluate("this.scrollIntoView({ block: 'center' })")
            sleep 0.3; submit_el.click
          end
        else
          browser.keyboard.type(:Enter)
        end
      else
        browser.keyboard.type(:Enter)
      end

      sleep 2

      # If still on login page, try Enter as fallback
      if browser.current_url.to_s.include?('/login')
        logger.info '[ChefsWarehouse] perform_login_steps: still on login page, pressing Enter'
        begin
          password_el_retry = browser.at_css("##{login_result['passwordId']}")
          password_el_retry&.focus
        rescue StandardError; nil; end
        browser.keyboard.type(:Enter)
      end

      wait_for_page_load
      sleep 5
    end

    public

    # Browser-based catalog scraper (fallback).
    def browser_scrape_catalog(search_terms, max_per_term: 50, &on_batch)
      results = []
      # Target: if we get 500+ products from categories, only do 10 strategic searches
      # Otherwise, do all searches to ensure coverage
      category_target = 500
      search_phase_limit = nil

      with_browser do
        # Login if needed
        unless restore_session && (navigate_to(BASE_URL) || true) && logged_in?
          perform_login_steps
          sleep 2
          raise AuthenticationError, 'Could not log in for catalog import' unless logged_in?

          save_session
        end

        # Phase 1: Browse categories for broad coverage
        logger.info "[ChefsWarehouse] Phase 1: Browsing #{CW_CATEGORIES.size} categories"
        CW_CATEGORIES.each do |category|
          begin
            products = browse_category(category, max: max_per_term)
            products.each { |p| p[:category] ||= category.to_s.titleize }
            if on_batch
              on_batch.call(products)
            else
              results.concat(products)
            end
            logger.info "[ChefsWarehouse] Category '#{category}': #{products.size} products"
          rescue StandardError => e
            logger.warn "[ChefsWarehouse] Category browse failed for '#{category}': #{e.class}: #{e.message}"
          end
          rate_limit_delay
        end

        # Decide how many searches to run based on category results
        total_so_far = on_batch ? 0 : results.size # When streaming, we don't track total locally
        if !on_batch && results.size >= category_target
          search_phase_limit = 10
          logger.info "[ChefsWarehouse] Categories yielded #{results.size} products (target: #{category_target}). Limiting search phase to #{search_phase_limit} terms."
        else
          logger.info "[ChefsWarehouse] Running full search phase."
        end

        # Phase 2: Search terms for items missed in categories
        terms_to_search = search_phase_limit ? search_terms.first(search_phase_limit) : search_terms
        logger.info "[ChefsWarehouse] Phase 2: Searching with #{terms_to_search.size} terms"

        terms_to_search.each do |term|
          begin
            products = search_supplier_catalog(term, max: max_per_term)
            if on_batch
              on_batch.call(products)
            else
              results.concat(products)
            end
            logger.info "[ChefsWarehouse] Search '#{term}': #{products.size} products"
          rescue StandardError => e
            logger.warn "[ChefsWarehouse] Search failed for '#{term}': #{e.class}: #{e.message}"
          end
          rate_limit_delay
        end
      end

      # When streaming via on_batch, return empty array (caller already has the data)
      return [] if on_batch

      # De-duplicate by SKU
      deduped = results.uniq { |r| r[:supplier_sku] }
      logger.info "[ChefsWarehouse] Total unique products: #{deduped.size} (from #{results.size} raw)"
      deduped
    end

    private

    # ── Field discovery ─────────────────────────────────────────────
    # Iterates an array of CSS selectors, returns the first visible element found
    def discover_field(selectors, label)
      selectors.each do |sel|
        elements = browser.css(sel)
        elements.each do |el|
          visible = begin
            el.evaluate(<<~JS)
              var s = window.getComputedStyle(this);
              s.display !== 'none' && s.visibility !== 'hidden' &&
              s.opacity !== '0' && this.offsetWidth > 0 && this.offsetHeight > 0
            JS
          rescue StandardError
            false
          end

          if visible
            logger.info "[ChefsWarehouse] Found #{label} field via '#{sel}'"
            return el
          end
        end
      rescue StandardError => e
        logger.debug "[ChefsWarehouse] Selector '#{sel}' raised: #{e.message}"
      end

      # Fallback: try to find ANY input by scanning all inputs on page
      if label.include?('email') || label.include?('username')
        fallback = begin
          browser.evaluate(<<~JS)
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
        rescue StandardError
          nil
        end

        if fallback && fallback['found']
          all_inputs = browser.css('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])')
          idx = fallback['index']
          if idx && idx < all_inputs.length
            el = all_inputs[idx]
            guess_note = fallback['isGuess'] ? ' (best guess)' : ''
            logger.info "[ChefsWarehouse] Found #{label} field via JS scan: type=#{fallback['type']}, name=#{fallback['name']}#{guess_note}"
            return el
          end
        end
      end

      if label.include?('password')
        pw_el = begin
          browser.at_css("input[type='password']")
        rescue StandardError
          nil
        end
        if pw_el
          logger.info "[ChefsWarehouse] Found password field via type='password' fallback"
          return pw_el
        end
      end

      logger.warn "[ChefsWarehouse] Could not find #{label} field with any selector"
      nil
    end

    # ── Fill a specific element with value ──────────────────────────
    # For Vue.js SPAs, use JavaScript-based filling to avoid stale element references
    def fill_element(element, value, label)
      # First try to get a stable selector for the element
      selector = get_element_selector(element)
      safe_value = js_string(value)

      # Use JavaScript to fill the field - more robust for SPAs
      filled = begin
        browser.evaluate(<<~JS)
          (function() {
            var el = document.querySelector('#{selector}');
            if (!el) return false;

            var val = #{safe_value};
            // Clear and set value using native setter to trigger Vue/React bindings
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            el.focus();
            el.dispatchEvent(new Event('focus', { bubbles: true }));
            nativeSetter.call(el, '');
            el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
            nativeSetter.call(el, val);

            // Vue 3 v-model listens for InputEvent, not generic Event
            el.dispatchEvent(new InputEvent('input', { bubbles: true, data: val, inputType: 'insertText' }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.dispatchEvent(new Event('blur', { bubbles: true }));

            return el.value === val;
          })()
        JS
      rescue StandardError
        false
      end

      if filled
        logger.info "[ChefsWarehouse] Filled #{label} via JS (selector: #{selector})"
        return
      end

      # Fallback: try direct element interaction
      begin
        element.focus
        element.type(value, :clear)
        logger.info "[ChefsWarehouse] Filled #{label} via focus+type"
      rescue Ferrum::NodeNotFoundError, Ferrum::BrowserError => e
        logger.debug "[ChefsWarehouse] Element interaction failed for #{label}: #{e.message}"
        # Element was removed from DOM - try finding it again
        retry_fill_by_label(label, value)
      end
    end

    # Get a CSS selector that can identify this element
    def get_element_selector(element)
      selector = begin
        element.evaluate(<<~JS)
          (function() {
            var el = this;
            if (el.id) return '#' + el.id;
            if (el.name) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
            if (el.type) return el.tagName.toLowerCase() + '[type="' + el.type + '"]';
            return el.tagName.toLowerCase();
          })()
        JS
      rescue StandardError
        nil
      end
      selector || 'input'
    end

    # Retry filling a field by searching for it again
    def retry_fill_by_label(label, value)
      safe_value = js_string(value)

      if label.include?('email') || label.include?('username')
        browser.evaluate(<<~JS)
          (function() {
            var val = #{safe_value};
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            function fillInput(inp, v) {
              inp.focus();
              inp.dispatchEvent(new Event('focus', { bubbles: true }));
              nativeSetter.call(inp, '');
              inp.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
              nativeSetter.call(inp, v);
              inp.dispatchEvent(new InputEvent('input', { bubbles: true, data: v, inputType: 'insertText' }));
              inp.dispatchEvent(new Event('change', { bubbles: true }));
              inp.dispatchEvent(new Event('blur', { bubbles: true }));
            }
            // CW uses type=text for email field, not type=email
            var pwField = document.querySelector('input[type="password"]');
            if (pwField) {
              var container = pwField.closest('form') || pwField.parentElement?.parentElement?.parentElement;
              if (container) {
                var textInputs = container.querySelectorAll('input[type="text"], input[type="email"]');
                for (var inp of textInputs) {
                  if (inp.offsetParent !== null) {
                    fillInput(inp, val);
                    return true;
                  }
                }
              }
            }
            // Fallback to any visible text/email input
            var inputs = document.querySelectorAll('input[type="email"], input[type="text"]');
            for (var inp of inputs) {
              if (inp.offsetParent !== null) {
                fillInput(inp, val);
                return true;
              }
            }
            return false;
          })()
        JS
        logger.info "[ChefsWarehouse] Filled #{label} via retry JS scan"
      elsif label.include?('password')
        browser.evaluate(<<~JS)
          (function() {
            var val = #{safe_value};
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            var inputs = document.querySelectorAll('input[type="password"]');
            for (var inp of inputs) {
              if (inp.offsetParent !== null) {
                inp.focus();
                inp.dispatchEvent(new Event('focus', { bubbles: true }));
                nativeSetter.call(inp, '');
                inp.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
                nativeSetter.call(inp, val);
                inp.dispatchEvent(new InputEvent('input', { bubbles: true, data: val, inputType: 'insertText' }));
                inp.dispatchEvent(new Event('change', { bubbles: true }));
                inp.dispatchEvent(new Event('blur', { bubbles: true }));
                return true;
              }
            }
            return false;
          })()
        JS
        logger.info "[ChefsWarehouse] Filled #{label} via retry JS scan"
      end
    end

    # ── URL-based login detection ───────────────────────────────────
    def url_indicates_login_success?
      current = begin
        browser.current_url.to_s.downcase
      rescue StandardError
        ''
      end
      # Only count as success if we're on a known authenticated-only page
      success_patterns = %w[/dashboard /account /my-account /orders /order-guide]
      success_patterns.any? { |p| current.include?(p) }
    end

    # ── Full page diagnostic dump ───────────────────────────────────
    def capture_page_diagnostics
      url = begin
        browser.current_url
      rescue StandardError
        'unknown'
      end
      title = begin
        browser.evaluate('document.title')
      rescue StandardError
        'unknown'
      end

      # Get all input fields on the page for debugging
      inputs_info = begin
        browser.evaluate(<<~JS)
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
      rescue StandardError
        'could not enumerate inputs'
      end

      # Get page body text snippet
      body_text = begin
        browser.evaluate('document.body?.innerText?.substring(0, 500)')
      rescue StandardError
        ''
      end

      # Get all iframes (login might be in an iframe)
      iframes_info = begin
        browser.evaluate(<<~JS)
          (function() {
            var frames = document.querySelectorAll('iframe');
            var info = [];
            for (var i = 0; i < frames.length; i++) {
              info.push({ src: frames[i].src || '', id: frames[i].id || '', name: frames[i].name || '' });
            }
            return JSON.stringify(info);
          })()
        JS
      rescue StandardError
        'none'
      end

      parts = [
        "URL: #{url}",
        "Title: '#{title}'",
        "Page inputs: #{inputs_info}",
        "Iframes: #{iframes_info}",
        "Page text: #{body_text.to_s.strip.truncate(300)}"
      ]

      parts.join(' | ')
    end

    # ── Product scraping ────────────────────────────────────────────
    def scrape_product(sku)
      navigate_to("#{BASE_URL}/products/#{sku}/")

      return nil unless browser.at_css('.product-detail, .pdp-container')

      result = {
        supplier_sku: sku,
        supplier_name: extract_text('.product-name, h1.title'),
        current_price: extract_price(extract_text('.price, .product-price')),
        pack_size: extract_text('.pack-info, .unit-size'),
        in_stock: browser.at_css('.out-of-stock, .sold-out').nil?,
        scraped_at: Time.current
      }

      # Extract CS/PC piece pricing from the product detail page
      piece_data = extract_piece_pricing_from_pdp
      result[:piece_price] = piece_data[:piece_price] if piece_data[:piece_price]
      result[:piece_pack_size] = piece_data[:piece_pack_size] if piece_data[:piece_pack_size]

      result
    end

    # Extract piece (PC) pricing from a CW product detail page.
    #
    # CW's Vue.js SPA renders CS/PC toggle buttons as `button.variant-btn`
    # inside a `qty-uom-selector` container. The main product's toggles are
    # separate from the `recommended-product-variants` section at the bottom.
    #
    # Approach:
    #   1. Find variant-btn elements NOT inside recommended-product-variants
    #   2. Check if both CS and PC are present and enabled (not disabled)
    #   3. If currently on CS, click PC, wait for Vue re-render, read new price
    #   4. Click back to CS to restore default state
    #
    # Uses simple JS expressions (not IIFEs) because Ferrum handles those more reliably.
    def extract_piece_pricing_from_pdp
      piece_result = { piece_price: nil, piece_pack_size: nil }

      # Step 1: Check if this product has both CS and PC variant buttons.
      # Scope to the FIRST .product-details__buy-box — this is the main product's
      # buy area. Related/recommended product cards lower on the page have their
      # own .product-details__buy-box containers that we must ignore.
      variant_texts = browser.evaluate(
        'document.querySelector(".product-details__buy-box") ? ' \
        'Array.from(document.querySelector(".product-details__buy-box").querySelectorAll(".variant-btn")).map(function(b){' \
        'return b.innerText.trim()+(b.classList.contains("disabled")?"*":"")+(b.classList.contains("selected")?"!":"")' \
        '}).join(",") : ""'
      )

      logger.debug "[ChefsWarehouse] Main product variant buttons: #{variant_texts}"

      return piece_result if variant_texts.blank?

      # Parse variant info: look for both CS and PC, both enabled
      variants = variant_texts.split(',').map(&:strip).reject(&:empty?)
      has_cs = variants.any? { |v| v.start_with?('CS') && !v.include?('*') }
      has_pc = variants.any? { |v| v.start_with?('PC') && !v.include?('*') }

      unless has_cs && has_pc
        logger.debug "[ChefsWarehouse] Product doesn't have both CS and PC enabled (variants: #{variant_texts})"
        return piece_result
      end

      # Step 2: Read the current (case) price from the first buy-box
      case_price = browser.evaluate(
        'document.querySelector(".product-details__buy-box") ? ' \
        'Array.from(document.querySelector(".product-details__buy-box").querySelectorAll("span")).filter(function(s){' \
        'var m=s.innerText.trim().match(/^\\$(\\d+[,\\d]*\\.\\d{2})/);return m!==null' \
        '}).map(function(s){' \
        'return parseFloat(s.innerText.trim().match(/\\$(\\d+[,\\d]*\\.\\d{2})/)[1].replace(",",""))' \
        '})[0] : null'
      )

      # Fallback: try the first product-details container
      if !case_price.is_a?(Numeric) || case_price <= 0
        case_price = browser.evaluate(
          'document.querySelector(".product-details") ? ' \
          'Array.from(document.querySelector(".product-details").querySelectorAll("span")).filter(function(s){' \
          'var m=s.innerText.trim().match(/^\\$(\\d+[,\\d]*\\.\\d{2})/);return m!==null' \
          '}).map(function(s){' \
          'return parseFloat(s.innerText.trim().match(/\\$(\\d+[,\\d]*\\.\\d{2})/)[1].replace(",",""))' \
          '})[0] : null'
        )
      end

      logger.debug "[ChefsWarehouse] Current case price: $#{case_price}"

      unless case_price.is_a?(Numeric) && case_price > 0
        logger.debug "[ChefsWarehouse] Could not read case price, skipping PC extraction"
        return piece_result
      end

      # Step 3: Click the PC button in the FIRST buy-box only
      clicked = browser.evaluate(
        'document.querySelector(".product-details__buy-box") ? ' \
        'Array.from(document.querySelector(".product-details__buy-box").querySelectorAll(".variant-btn")).filter(function(b){' \
        'return b.innerText.trim()==="PC" && !b.classList.contains("disabled")' \
        '}).map(function(b){b.click();return true})[0] || false : false'
      )

      unless clicked
        logger.debug "[ChefsWarehouse] Could not click PC button in main buy-box"
        return piece_result
      end

      # Step 4: Wait for Vue re-render and read the piece price
      sleep 2

      piece_price = browser.evaluate(
        'document.querySelector(".product-details__buy-box") ? ' \
        'Array.from(document.querySelector(".product-details__buy-box").querySelectorAll("span")).filter(function(s){' \
        'var m=s.innerText.trim().match(/^\\$(\\d+[,\\d]*\\.\\d{2})/);return m!==null' \
        '}).map(function(s){' \
        'return parseFloat(s.innerText.trim().match(/\\$(\\d+[,\\d]*\\.\\d{2})/)[1].replace(",",""))' \
        '})[0] : null'
      )

      logger.debug "[ChefsWarehouse] Price after clicking PC: $#{piece_price}"

      # Validate: piece price must differ from case price
      if piece_price.is_a?(Numeric) && piece_price > 0 && piece_price != case_price
        piece_result[:piece_price] = piece_price

        # Read piece pack size from the main product area
        pack_text = browser.evaluate(
          'document.querySelector(".product-details") ? ' \
          'Array.from(document.querySelector(".product-details").querySelectorAll("span,div")).filter(function(s){' \
          'return s.innerText.trim().match(/^\\d+x\\d+|^\\d+\\s*(CT|OZ|LB|EA|PC)/i) && s.children.length===0' \
          '}).map(function(s){return s.innerText.trim()})[0] : null'
        )
        piece_result[:piece_pack_size] = pack_text if pack_text.present?

        logger.info "[ChefsWarehouse] Extracted piece price: $#{piece_price} (case: $#{case_price})"
      else
        logger.debug "[ChefsWarehouse] Piece price same as case or invalid — not a dual-UOM product"
      end

      # Step 5: Click back to CS to restore default state
      browser.evaluate(
        'document.querySelector(".product-details__buy-box") ? ' \
        'Array.from(document.querySelector(".product-details__buy-box").querySelectorAll(".variant-btn")).filter(function(b){' \
        'return b.innerText.trim()==="CS" && !b.classList.contains("disabled")' \
        '}).map(function(b){b.click();return true})[0] || false : false'
      )
      sleep 0.5

      piece_result
    rescue StandardError => e
      logger.debug "[ChefsWarehouse] Error extracting piece pricing: #{e.message}"
      { piece_price: nil, piece_pack_size: nil }
    end

    # ── Catalog search ──────────────────────────────────────────────
    def search_supplier_catalog(term, max: 20)
      encoded = CGI.escape(term)
      navigate_to("#{BASE_URL}/search?q=#{encoded}")
      sleep 2 # SPA rendering time

      # CW stores product data as JSON in hidden inputs with data-object attribute
      products = extract_products_from_data_objects(max)

      # Fallback: parse visible .product-item elements
      products = extract_products_from_items(max) if products.empty?

      products
    end

    # Primary extraction: CW embeds JSON in hidden input[data-sku][data-object]
    def extract_products_from_data_objects(max)
      raw = begin
        browser.evaluate(<<~JS)
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
                    pack_size: obj.pack_size || "",
                    unit_of_measure: obj.unit_of_measure || "",
                    url: obj.url || "",
                    in_stock: true
                  });
                }
              } catch(e) {}
            }
            return results;
          })()
        JS
      rescue StandardError
        []
      end

      (raw || []).map do |item|
        pack = item['pack_size'].to_s.strip.presence
        product_url = item['url'].to_s.presence
        product_url = "#{BASE_URL}#{product_url}" if product_url && !product_url.start_with?('http')
        {
          supplier_sku: item['sku'],
          supplier_name: item['name'],
          current_price: item['price'].is_a?(Numeric) ? item['price'] : nil,
          pack_size: pack,
          supplier_url: product_url,
          in_stock: item['in_stock'] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    end

    # Fallback: parse visible .product-item divs
    def extract_products_from_items(max)
      raw = begin
        browser.evaluate(<<~JS)
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
      rescue StandardError
        []
      end

      (raw || []).map do |item|
        sku = item['sku']
        {
          supplier_sku: sku,
          supplier_name: item['name'],
          current_price: item['price'].is_a?(Numeric) ? item['price'] : nil,
          pack_size: item['pack'].presence,
          supplier_url: sku.present? ? "#{BASE_URL}/products/#{sku}/" : nil,
          in_stock: item['in_stock'] != false,
          category: nil,
          scraped_at: Time.current
        }
      end
    end

    # ── Checkout helpers ────────────────────────────────────────────

    def navigate_to_cart_page
      # Try the main cart URL first
      navigate_to("#{BASE_URL}/cart")
      sleep 3 # Wait for Vue SPA to render

      # Check if we're on a cart page with items
      page_text = browser.evaluate('document.body.innerText') || ''

      # If the page doesn't look like a cart, try alternate URLs
      unless page_text.match?(/\$\d+\.\d{2}/) || page_text.downcase.include?('cart') || page_text.downcase.include?('shopping')
        logger.info "[ChefsWarehouse] /cart didn't load cart content, trying /account-dashboard/cart/"
        navigate_to("#{BASE_URL}/account-dashboard/cart/")
        sleep 3
        page_text = browser.evaluate('document.body.innerText') || ''
      end

      # Log the page structure for DOM discovery
      logger.info "[ChefsWarehouse] Cart page URL: #{browser.current_url}"
      logger.info "[ChefsWarehouse] Cart page text (first 500 chars): #{page_text[0..500]}"

      # Log DOM structure for selector discovery
      dom_info = browser.evaluate(<<~JS)
        (function() {
          var info = { url: window.location.href, title: document.title };
          info.has_table = !!document.querySelector('table');
          info.has_cart_class = !!document.querySelector('[class*="cart"]');
          info.has_price = !!document.body.innerText.match(/\\$\\d+\\.\\d{2}/);
          info.buttons = Array.from(document.querySelectorAll('button, a.btn, [role="button"]'))
            .slice(0, 20)
            .map(function(b) { return { tag: b.tagName, text: b.innerText.trim().substring(0, 50), classes: b.className.substring(0, 80) }; });
          info.inputs = Array.from(document.querySelectorAll('input[type="number"]'))
            .map(function(i) { return { name: i.name, value: i.value, classes: i.className.substring(0, 80) }; });
          return info;
        })()
      JS

      logger.info "[ChefsWarehouse] Cart page DOM: #{dom_info.inspect}"
    end

    def extract_cart_data
      cart_data = browser.evaluate(<<~JS)
        (function() {
          var result = { items: [], subtotal: 0, item_count: 0, unavailable: [], raw_prices: [], badge_count: 0 };

          // === ITEM COUNT: Trust the shopping cart badge (most reliable) ===
          var cartBadge = document.querySelector('.shopping-cart-btn, .mobile-shopping-cart-btn, [class*="cart-count"]');
          if (cartBadge) {
            var badgeNum = parseInt(cartBadge.innerText.trim());
            if (!isNaN(badgeNum)) result.badge_count = badgeNum;
          }

          var pageText = document.body.innerText;

          // === SUBTOTAL: Look for labeled amounts ===
          var subtotalPatterns = [
            /subtotal[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /cart\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /estimated\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i
          ];
          for (var pattern of subtotalPatterns) {
            var match = pageText.match(pattern);
            if (match) {
              result.subtotal = parseFloat(match[1].replace(',', ''));
              break;
            }
          }

          // === CART ITEMS: Only count elements with quantity inputs ===
          // Actual cart items have qty inputs; recommendation products just have "Add to Cart" buttons
          var qtyInputs = document.querySelectorAll('input[type="number"]');
          var cartItems = [];

          qtyInputs.forEach(function(input) {
            if (input.offsetParent === null) return; // skip hidden

            // Walk up to find the containing cart item element
            var container = input.closest(
              '[class*="cart-item"], [class*="line-item"], [class*="product-row"], ' +
              'tr, li, .card, [class*="cart"] > div'
            );
            if (!container) container = input.parentElement && input.parentElement.parentElement;
            if (!container) return;

            // Skip if this container is inside a recommendation/suggested section
            var inRecommendation = container.closest('[class*="recommend"], [class*="suggest"], [class*="trending"], [class*="carousel"]');
            if (inRecommendation) return;

            var elText = container.innerText || '';
            var priceMatch = elText.match(/\\$([\\d,]+\\.\\d{2})/);
            var qty = parseInt(input.value) || 1;
            var name = elText.split('\\n')[0].trim().substring(0, 80);
            var price = priceMatch ? parseFloat(priceMatch[1].replace(',', '')) : 0;
            var sku = (container.getAttribute('data-sku') || container.getAttribute('data-product-id') || '').trim();

            var isUnavailable = elText.toLowerCase().match(/out of stock|unavailable|discontinued/);

            if (price > 0) {
              var item = { name: name, price: price, quantity: qty, sku: sku };
              cartItems.push(item);
              if (isUnavailable) result.unavailable.push(item);
            }
          });

          result.items = cartItems;
          result.raw_prices = (pageText.match(/\\$[\\d,]+\\.\\d{2}/g) || []);

          // Item count: prefer badge (most reliable), then found cart items
          result.item_count = result.badge_count || cartItems.length;

          // Subtotal: if no labeled subtotal, sum the cart items we found
          if (result.subtotal === 0 && cartItems.length > 0) {
            result.subtotal = cartItems.reduce(function(sum, item) {
              return sum + (item.price * item.quantity);
            }, 0);
          }

          // Last resort subtotal: largest dollar amount on page
          if (result.subtotal === 0 && result.raw_prices.length > 0) {
            var amounts = result.raw_prices.map(function(p) { return parseFloat(p.replace(/[\\$,]/g, '')); });
            result.subtotal = Math.max.apply(null, amounts);
          }

          return result;
        })()
      JS

      logger.info "[ChefsWarehouse] Cart extraction: badge=#{cart_data['badge_count']}, items_found=#{(cart_data['items'] || []).size}, subtotal=#{cart_data['subtotal']}"

      {
        items: cart_data['items'] || [],
        subtotal: cart_data['subtotal'] || 0,
        item_count: cart_data['item_count'] || 0,
        unavailable_items: (cart_data['unavailable'] || []).map { |i| { sku: i['sku'], name: i['name'], message: 'Out of stock' } },
        raw_prices: cart_data['raw_prices'] || []
      }
    end

    def proceed_to_checkout_page
      # Navigate to the checkout REVIEW page — DO NOT click order-finalizing buttons.
      # Only click navigation buttons (checkout, proceed, review).
      # "Place Order" / "Submit" are handled by click_place_order_button AFTER the dry run gate.
      #
      # CW has no separate checkout page — the cart page IS the checkout page.
      # If we detect a "Submit Order" button on the current page, we're already there.
      clicked = browser.evaluate(<<~JS)
        (function() {
          var excludeClasses = ['search-button', 'clear-button', 'close-button'];

          function isExcluded(el) {
            var cls = (el.className || '').toLowerCase();
            for (var exc of excludeClasses) {
              if (cls.includes(exc)) return true;
            }
            return false;
          }

          // SAFETY: Order-finalizing text — never click these before dry run gate
          var orderFinalizing = /submit order|place order|complete order/i;

          // Phase 0: Check if we're already on the checkout page
          // (i.e. a "Submit Order" / "Place Order" button is visible — no navigation needed)
          var allButtons = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');
          for (var btn of allButtons) {
            var btnText = (btn.innerText || btn.value || '').trim().toLowerCase();
            if (orderFinalizing.test(btnText) && btn.offsetParent !== null) {
              return { clicked: true, text: 'Already on checkout page', method: 'already-on-checkout' };
            }
          }

          // Phase 1: Navigation text matches only
          var navTargets = ['checkout', 'proceed to checkout', 'proceed', 'continue to checkout', 'review order', 'view cart'];
          var elements = document.querySelectorAll('button, a.btn, a[class*="btn"], [role="button"], input[type="submit"]');

          for (var el of elements) {
            if (isExcluded(el)) continue;
            var text = (el.innerText || el.value || '').trim().toLowerCase();
            if (orderFinalizing.test(text)) continue;
            for (var target of navTargets) {
              if (text.includes(target)) {
                el.scrollIntoView({ behavior: 'instant', block: 'center' });
                el.click();
                return { clicked: true, text: el.innerText.trim(), tag: el.tagName, method: 'exact-text' };
              }
            }
          }

          // Phase 2: href-based navigation links (safe — just follows a URL)
          var links = document.querySelectorAll('a[href*="checkout"], a[href*="review"]');
          for (var link of links) {
            if (link.offsetParent !== null) {
              var linkText = (link.innerText || '').trim().toLowerCase();
              if (orderFinalizing.test(linkText)) continue;
              link.click();
              return { clicked: true, text: link.innerText.trim(), method: 'href-match' };
            }
          }

          return { clicked: false };
        })()
      JS

      if clicked && clicked['clicked']
        logger.info "[ChefsWarehouse] Checkout navigation: #{clicked.inspect}"
      else
        logger.warn "[ChefsWarehouse] Could not find checkout button — logging page state"
        log_page_state('checkout_button_not_found')
        raise ScrapingError, 'Could not find checkout/proceed button'
      end

      sleep 5 unless clicked['method'] == 'already-on-checkout' # No need to wait if already there

      # Log checkout page structure for discovery
      logger.info "[ChefsWarehouse] Checkout page URL: #{browser.current_url}"
      page_text = browser.evaluate('document.body.innerText') || ''
      logger.info "[ChefsWarehouse] Checkout page text (first 500 chars): #{page_text[0..500]}"
    end

    def extract_checkout_data
      checkout_data = browser.evaluate(<<~JS)
        (function() {
          var text = document.body.innerText;
          var result = { total: 0, delivery_date: null, summary_text: text.substring(0, 1000) };

          // Extract total
          var totalPatterns = [
            /order\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /grand\\s*total[:\\s]*\\$([\\d,]+\\.\\d{2})/i,
            /amount\\s*due[:\\s]*\\$([\\d,]+\\.\\d{2})/i
          ];
          for (var pattern of totalPatterns) {
            var match = text.match(pattern);
            if (match) {
              result.total = parseFloat(match[1].replace(',', ''));
              break;
            }
          }

          // Extract delivery date
          var datePatterns = [
            /deliver[y]?\\s*(?:date)?[:\\s]*(\\w+ \\d{1,2},? \\d{4})/i,
            /ship\\s*(?:date)?[:\\s]*(\\w+ \\d{1,2},? \\d{4})/i,
            /estimated\\s*delivery[:\\s]*(\\w+ \\d{1,2},? \\d{4})/i,
            /(\\d{1,2}\\/\\d{1,2}\\/\\d{2,4})/
          ];
          for (var pattern of datePatterns) {
            var match = text.match(pattern);
            if (match) {
              result.delivery_date = match[1];
              break;
            }
          }

          // Capture available buttons for logging
          result.buttons = Array.from(document.querySelectorAll('button, input[type="submit"], a.btn'))
            .filter(function(b) { return b.offsetParent !== null; })
            .slice(0, 15)
            .map(function(b) { return { text: b.innerText.trim().substring(0, 50), tag: b.tagName, classes: b.className.substring(0, 80) }; });

          return result;
        })()
      JS

      logger.info "[ChefsWarehouse] Checkout data: #{checkout_data.inspect}"

      {
        total: checkout_data['total'].presence,
        delivery_date: checkout_data['delivery_date'],
        summary_text: checkout_data['summary_text'],
        buttons: checkout_data['buttons'] || []
      }
    end

    def click_place_order_button
      clicked = browser.evaluate(<<~JS)
        (function() {
          var targets = ['place order', 'submit order', 'complete order', 'confirm order'];
          var elements = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');

          for (var el of elements) {
            var text = (el.innerText || el.value || '').trim().toLowerCase();
            for (var target of targets) {
              if (text.includes(target)) {
                el.scrollIntoView({ behavior: 'instant', block: 'center' });
                el.click();
                return { clicked: true, text: el.innerText.trim() };
              }
            }
          }

          return { clicked: false };
        })()
      JS

      raise ScrapingError, 'Could not find place order button' unless clicked && clicked['clicked']

      logger.info "[ChefsWarehouse] Clicked place order: #{clicked.inspect}"
    end

    def wait_for_order_confirmation
      start_time = Time.current
      timeout = 30

      loop do
        page_text = browser.evaluate('document.body.innerText') || ''

        # Check for confirmation indicators
        if page_text.match?(/confirmation|order\s*#|order\s*number|thank\s*you|order\s*placed/i)
          # Extract confirmation number
          conf_match = page_text.match(/(?:order\s*#?|confirmation\s*#?)[:\s]*([A-Z0-9-]+)/i)
          total_match = page_text.match(/total[:\s]*\$[\d,]+\.\d{2}/i)

          confirmation_number = conf_match ? conf_match[1] : "CW-#{Time.current.strftime('%Y%m%d%H%M%S')}"
          total = total_match ? extract_price(total_match[0]) : nil

          logger.info "[ChefsWarehouse] Order confirmed: #{confirmation_number}"

          return {
            confirmation_number: confirmation_number,
            total: total,
            delivery_date: nil
          }
        end

        # Check for errors
        if page_text.match?(/error|failed|could not|unable to/i) && !page_text.match?(/confirmation/i)
          error_text = page_text[0..200]
          raise ScrapingError, "Checkout failed: #{error_text}"
        end

        raise ScrapingError, 'Checkout confirmation timeout (30s)' if Time.current - start_time > timeout

        sleep 1
      end
    end

    def log_page_state(context)
      page_info = browser.evaluate(<<~JS)
        (function() {
          return {
            url: window.location.href,
            title: document.title,
            text_preview: document.body.innerText.substring(0, 1000),
            button_count: document.querySelectorAll('button').length,
            link_count: document.querySelectorAll('a').length,
            input_count: document.querySelectorAll('input').length
          };
        })()
      JS

      logger.info "[ChefsWarehouse] Page state (#{context}): #{page_info.inspect}"
    end
  end
end
