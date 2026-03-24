# frozen_string_literal: true

namespace :wcw do
  desc 'Bootstrap WCW API session — browser login to capture cookies for API client'
  task bootstrap_session: :environment do
    supplier = Supplier.find_by(code: 'whatchefswant')
    abort 'WCW supplier not found' unless supplier

    credential = supplier.supplier_credentials.find_by(status: 'active')
    abort 'No active WCW credential' unless credential

    puts "=" * 60
    puts "WCW Session Bootstrap"
    puts "Credential: #{credential.username} (#{credential.status})"
    puts "=" * 60

    scraper = Scrapers::WhatChefsWantScraper.new(credential)

    puts "\nLogging in via browser (this opens a headless browser)..."
    scraper.login
    puts "Login successful!"

    # Verify API client has cookies
    api = scraper.api_client
    raw = credential.reload.session_data
    session = raw.is_a?(String) ? (JSON.parse(raw) rescue {}) : (raw || {})
    api_cookies = session['api_cookies'] || {}
    api_context = session['api_context'] || {}

    puts "\nAPI state:"
    puts "  Cookies: #{api_cookies.size}"
    puts "  Vendor ID: #{api_context['vendor_id']}"
    puts "  Location ID: #{api_context['location_id']}"
    puts "  Form ID: #{api_context['form_id']}"
    puts "  Verified Vendor ID: #{api_context['verified_vendor_id']}"

    if api_cookies.is_a?(Hash) && api_cookies.any? && api_context['vendor_id']
      puts "\nSession bootstrapped successfully! API client is ready."
    else
      # Try discover_context if cookies are there but context isn't
      if api_cookies.is_a?(Hash) && api_cookies.any? && !api_context['vendor_id']
        puts "\nCookies saved but context not discovered. Trying now..."
        api.restore_session
        if api.discover_context
          puts "Context discovered!"
          puts "  Vendor: #{api.vendor_id}"
          puts "  Location: #{api.location_id}"
          puts "  Form: #{api.form_id}"
        else
          puts "\nWARNING: Could not discover context. Session may be incomplete."
        end
      else
        puts "\nWARNING: Session may be incomplete. Try running again."
      end
    end
  end

  desc 'Test WCW API — search products, create draft, verify, delete (no order placed)'
  task test_cart: :environment do
    supplier = Supplier.find_by(code: 'whatchefswant')
    abort 'WCW supplier not found' unless supplier

    credential = supplier.supplier_credentials.find_by(status: 'active')
    abort 'No active WCW credential' unless credential

    puts "=" * 60
    puts "WCW Cart Test (API)"
    puts "Credential: #{credential.username} (#{credential.status})"
    puts "=" * 60

    scraper = Scrapers::WhatChefsWantScraper.new(credential)
    api = scraper.api_client

    # Try to restore session
    unless api.restore_session
      puts "\nNo API session — running bootstrap first..."
      scraper.login
      unless api.restore_session
        abort 'Could not establish API session. Run rake wcw:bootstrap_session first.'
      end
    end

    puts "\nAPI session active."
    puts "  Vendor: #{api.vendor_id}"
    puts "  Location: #{api.location_id}"
    puts "  Form: #{api.form_id}"

    # Step 1: Search for products
    search_term = ENV.fetch('SEARCH', 'chicken')
    puts "\n--- Step 1: Search products for '#{search_term}' ---"
    result = api.search_products(search_term, limit: 5)
    products = result&.dig('data', 'catalogProductsSearchRootQuery', 'contextualProducts')&.map { |cp| cp['canonicalProduct'] }&.compact || []
    puts "Found #{products.size} products:"
    products.each do |p|
      price = p.dig('unifiedPrice', 'defaultUnitPrice', 'netTieredPrices', 0, 'price', 'money') || 'N/A'
      unit = p.dig('unifiedPrice', 'defaultUnitPrice', 'unit') || ''
      puts "  #{p['itemCode']} — #{p['description'] || p['brandName']} (#{p['packSize']}) #{price}/#{unit}"
    end

    if products.empty?
      abort 'No products found — cannot test cart'
    end

    # Step 2: Create draft with first 2 products
    test_products = products.first(2)
    puts "\n--- Step 2: Create draft order (#{test_products.size} items) ---"
    cart_items = test_products.map do |p|
      price_val = p.dig('unifiedPrice', 'defaultUnitPrice', 'netTieredPrices', 0, 'price', 'float') || 0
      {
        product_id: p['id'],
        quantity: 1,
        price: price_val
      }
    end

    draft_result = api.create_draft(nil, cart_items)
    draft = draft_result&.dig('data', 'CreateOrUpdateDraftMutation')
    if draft
      puts "Draft created: id=#{draft['id']}, items=#{draft['itemCount']}"
    else
      puts "ERROR: Failed to create draft"
      puts "Response: #{draft_result.to_json[0..500]}" if draft_result
      abort 'Draft creation failed'
    end

    draft_id = draft['id']

    # Step 3: Verify draft contents
    puts "\n--- Step 3: Verify draft contents ---"
    draft_data = api.get_draft(draft_id)
    draft_detail = draft_data&.dig('data', 'draft')
    if draft_detail
      puts "Draft #{draft_id}:"
      puts "  Items: #{draft_detail['itemCount']}"
      puts "  Date: #{draft_detail['date']}"
      (draft_detail['products'] || []).each do |p|
        name = p.dig('multiUnitProduct', 'name') || p['itemCode']
        puts "    #{p['itemCode']} — #{name} (qty: #{p['quantity']})"
      end
    else
      puts "WARNING: Could not verify draft contents"
    end

    # Step 4: Clear draft
    puts "\n--- Step 4: Clear draft (delete items) ---"
    api.delete_draft_items(draft_id)
    puts "Draft items cleared."

    # Verify it's empty
    verify = api.get_draft(draft_id)
    verify_detail = verify&.dig('data', 'draft')
    remaining = verify_detail&.dig('itemCount') || 'unknown'
    puts "Draft items after clear: #{remaining}"

    puts "\n#{'=' * 60}"
    puts "SUCCESS — WCW cart round-trip complete, no order placed."
    puts "=" * 60
  end

  desc 'Test WCW API — fetch order guide via API'
  task test_order_guide: :environment do
    supplier = Supplier.find_by(code: 'whatchefswant')
    abort 'WCW supplier not found' unless supplier

    credential = supplier.supplier_credentials.find_by(status: 'active')
    abort 'No active WCW credential' unless credential

    scraper = Scrapers::WhatChefsWantScraper.new(credential)
    api = scraper.api_client

    unless api.restore_session
      puts 'No API session — running bootstrap...'
      scraper.login
      abort 'Could not establish session' unless api.restore_session
    end

    puts "Fetching order guides..."
    guides = api.get_order_guides
    forms = guides&.dig('data', 'company', 'forms') || []
    puts "Order guides: #{forms.size}"
    forms.each { |f| puts "  #{f['id']} — #{f['name']} (empty: #{f['isEmpty']})" }

    puts "\nFetching order guide items (first 25)..."
    items_result = api.get_order_guide_items(limit: 25)
    sections = items_result&.dig('data', 'formProducts', 'sectionsWithCount', 'sections') || []
    total = items_result&.dig('data', 'formProducts', 'sectionsWithCount', 'fullCount') || 0

    puts "Total items in guide: #{total}"
    sections.each do |section|
      puts "\n  Section: #{section['title']}"
      (section['multiUnitProducts'] || []).each do |mup|
        product = (mup['products'] || []).first
        next unless product
        cp = product['canonicalproduct'] || {}
        price = cp.dig('unifiedPrice', 'defaultUnitPrice', 'netTieredPrices', 0, 'price', 'money') || 'N/A'
        puts "    #{mup['itemCode']} — #{mup['name']} (#{cp['packSize']}) #{price}"
      end
    end
  end
end
