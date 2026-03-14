# frozen_string_literal: true

namespace :sysco do
  desc 'Capture exact GraphQL queries from Sysco SPA for API-based scraping'
  task capture_queries: :environment do
    credential = SupplierCredential.joins(:supplier)
                                   .where('suppliers.name ILIKE ?', '%sysco%')
                                   .first
    abort 'No Sysco credential found' unless credential

    Rails.logger = Logger.new($stdout)
    Rails.logger.level = :info

    scraper = Scrapers::SyscoScraper.new(credential)
    captured = {}

    scraper.send(:with_browser) do
      b = scraper.send(:browser)
      b.page.command('Network.enable')

      # Capture all GraphQL requests
      b.on('Network.requestWillBeSent') do |params|
        url = params['request']['url']
        next unless url.include?('gateway-api.shop.sysco.com/graphql')

        post_data = params.dig('request', 'postData')
        next unless post_data

        headers = params['request']['headers']
        parsed = JSON.parse(post_data) rescue next
        op = parsed['operationName']
        next if captured[op] # only capture first instance

        captured[op] = {
          query: parsed['query'],
          variables: parsed['variables'],
          headers: headers
        }
      end

      # Login
      scraper.send(:ensure_logged_in)
      abort '❌ Not authenticated' unless scraper.send(:logged_in?)

      # Trigger search
      puts '=== Triggering search to capture SearchProducts + Prices ==='
      captured.clear
      scraper.send(:perform_spa_search, 'chicken')
      sleep 6

      # Navigate to lists
      puts '=== Navigating to lists to capture GetLists + GetListItemsV2 ==='
      begin
        b.goto('https://shop.sysco.com/app/lists')
      rescue Ferrum::PendingConnectionsError
        nil
      end
      sleep 6
    end

    # Output the captured queries as Ruby constants
    target_ops = %w[SearchProducts Prices GetLists GetListItemsV2 GetProducts]

    puts "\n\n#{'=' * 70}"
    puts "CAPTURED GRAPHQL QUERIES"
    puts "#{'=' * 70}\n\n"

    target_ops.each do |op|
      data = captured[op]
      unless data
        puts "# ❌ #{op} — NOT CAPTURED"
        puts ""
        next
      end

      query = data[:query]
      # Clean up whitespace
      query = query.gsub(/\n\s*\n/, "\n").strip

      puts "# ✅ #{op}"
      puts "#{op.underscore.upcase}_QUERY = <<~GQL"
      query.each_line { |line| puts "  #{line.rstrip}" }
      puts "GQL"
      puts ""

      # Show variable structure
      puts "# Variables template:"
      puts "# #{JSON.pretty_generate(data[:variables]).gsub("\n", "\n# ")}"
      puts ""
    end

    # Also output the syy-authorization header from any captured request
    any_data = captured.values.first
    if any_data
      syy_auth = any_data[:headers]['syy-authorization']
      if syy_auth
        decoded = JSON.parse(Base64.decode64(syy_auth)) rescue nil
        puts "\n# syy-authorization structure:"
        puts "# #{JSON.pretty_generate(decoded)}" if decoded
      end
    end

    # Show all operations captured (in case we missed naming)
    puts "\n\n# All operations captured:"
    captured.each_key { |op| puts "#   #{op}" }
  end
end
