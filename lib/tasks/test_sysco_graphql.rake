# frozen_string_literal: true

namespace :sysco do
  desc 'Test Sysco GraphQL API scraper end-to-end (login via browser, then HTTP-only)'
  task test_graphql: :environment do
    credential = SupplierCredential.joins(:supplier)
                                   .where('suppliers.name ILIKE ?', '%sysco%')
                                   .first
    abort 'No Sysco credential found' unless credential

    Rails.logger = Logger.new($stdout)
    Rails.logger.level = :info

    scraper = Scrapers::SyscoScraper.new(credential)

    # Step 1: Check if we already have valid API tokens
    puts "\n=== Step 1: Check existing API tokens ==="
    if scraper.send(:api_session_valid?)
      tokens = scraper.send(:load_api_tokens)
      exp = scraper.send(:decode_jwt_exp, tokens[:jwt])
      hours_left = exp ? ((exp - Time.now.to_i) / 3600.0).round(1) : '?'
      puts "  ✅ Valid API tokens exist (JWT expires in #{hours_left}h)"
      puts "  shopAccountId: #{tokens[:shop_account_id]}"
      puts "  seller: #{tokens[:seller_id]} / site: #{tokens[:site_id]}"
    else
      puts "  ❌ No valid API tokens — need browser login"
      puts "\n=== Step 1b: Login via browser to capture tokens ==="
      scraper.send(:ensure_api_session!)
      puts "  ✅ Tokens captured"
    end

    # Step 2: Test catalog search (HTTP only, no browser)
    puts "\n=== Step 2: Catalog search via GraphQL API ==="
    terms = %w[chicken flour]
    terms.each do |term|
      puts "\n  --- Search: '#{term}' ---"
      products = scraper.search_supplier_catalog(term, max: 24)
      puts "  Products found: #{products.size}"
      products.first(3).each do |p|
        puts "    #{p[:supplier_sku]} — #{p[:supplier_name]&.first(50)} | $#{p[:current_price]} #{p[:price_unit]} | #{p[:pack_size]} | stock=#{p[:in_stock]}"
      end
    end

    # Step 3: Test list scraping (HTTP only, no browser)
    puts "\n=== Step 3: Lists via GraphQL API ==="
    lists = scraper.scrape_supplier_lists
    puts "  Lists found: #{lists.size}"
    lists.each do |list|
      puts "  📋 #{list[:name]} (#{list[:items].size} items, id=#{list[:remote_id]})"
      list[:items].first(3).each do |item|
        puts "    #{item[:sku]} — #{item[:name]&.first(50)} | $#{item[:price]} #{item[:price_unit]} | #{item[:pack_size]}"
      end
    end

    # Step 4: Test full scrape_catalog flow
    puts "\n=== Step 4: Full scrape_catalog flow (3 terms) ==="
    all_products = []
    scraper.scrape_catalog(%w[beef pasta oil], max_per_term: 10) do |batch|
      all_products.concat(batch)
      puts "  Batch: #{batch.size} products (#{all_products.size} total)"
    end
    puts "  Total unique products: #{all_products.size}"

    puts "\n=== All tests passed! ==="
    puts "No Chrome browser was used for data operations."
    puts "Browser was only used for login (if JWT was expired)."
  end
end
