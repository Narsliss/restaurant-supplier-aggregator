# frozen_string_literal: true

namespace :sysco do
  desc 'Intercept Sysco API calls and test direct HTTP access'
  task discover_api: :environment do
    credential = SupplierCredential.joins(:supplier)
                                   .where('suppliers.name ILIKE ?', '%sysco%')
                                   .first

    abort 'No Sysco credential found' unless credential

    Rails.logger = Logger.new($stdout)
    Rails.logger.level = :info

    scraper = Scrapers::SyscoScraper.new(credential)

    jwt = nil
    all_headers = nil
    cookie_header = nil
    search_post_data = nil

    scraper.send(:with_browser) do
      b = scraper.send(:browser)
      b.page.command('Network.enable')

      # Capture the exact SearchProducts request
      b.on('Network.requestWillBeSent') do |params|
        url = params['request']['url']
        next unless url.include?('gateway-api.shop.sysco.com/graphql')

        post_data = params.dig('request', 'postData')
        next unless post_data&.include?('SearchProducts')
        next if post_data&.include?('Typeahead')

        all_headers = params['request']['headers']
        search_post_data = post_data
      end

      puts "=== Login ==="
      scraper.send(:ensure_logged_in)
      abort '❌ Not authenticated' unless scraper.send(:logged_in?)
      puts '✅ Logged in'

      jwt = b.evaluate(<<~JS)
        (function() {
          var raw = localStorage.getItem('gatewayCredentials');
          if (!raw) return null;
          try { var p = JSON.parse(raw); return p.access_token || p; } catch(e) { return raw; }
        })()
      JS

      scraper.send(:perform_spa_search, 'chicken')
      sleep 5

      abort '❌ No SearchProducts captured' unless all_headers

      cookie_header = all_headers['cookie']

      # Show what syy-authorization actually is
      syy_auth = all_headers['syy-authorization']
      if syy_auth
        decoded = JSON.parse(Base64.decode64(syy_auth)) rescue nil
        puts "\nsyy-authorization decoded: #{decoded}" if decoded
      end
    end

    # Phase 2: Direct HTTP
    puts "\n#{'=' * 60}"
    puts '=== Direct HTTP API calls (NO BROWSER) ==='
    puts "#{'=' * 60}"

    require 'net/http'
    require 'uri'

    uri = URI.parse('https://gateway-api.shop.sysco.com/graphql')

    # Helper to make GraphQL call
    make_call = lambda do |label, body, headers_hash|
      puts "\n--- #{label} ---"
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri.request_uri)
      req.body = body
      headers_hash.each { |k, v| req[k] = v }
      resp = http.request(req)
      parsed = JSON.parse(resp.body) rescue nil
      puts "  Status: #{resp.code}"
      if resp.code == '200' && parsed
        puts "  ✅ Success"
        # Deep-print the response structure
        print_structure(parsed, '  ')
      elsif parsed
        puts "  ❌ #{parsed.dig('errors', 0, 'message') || resp.body[0..300]}"
      else
        puts "  ❌ #{resp.body[0..300]}"
      end
      [resp.code.to_i, parsed]
    end

    # Print nested hash/array structure
    define_method(:print_structure) do |obj, indent, depth = 0|
      return if depth > 4
      case obj
      when Hash
        obj.each do |k, v|
          case v
          when Hash
            puts "#{indent}#{k}:"
            print_structure(v, indent + '  ', depth + 1)
          when Array
            puts "#{indent}#{k}: Array(#{v.size})"
            print_structure(v.first, indent + '  [0] ', depth + 1) if v.first && v.size > 0
          when String
            puts "#{indent}#{k}: #{v[0..120]}"
          when NilClass
            puts "#{indent}#{k}: null"
          else
            puts "#{indent}#{k}: #{v}"
          end
        end
      end
    end

    # Build headers that mirror the browser exactly
    base_headers = {}
    all_headers.each do |k, v|
      next if k.start_with?(':')
      next if k.downcase == 'content-length'
      next if k.downcase == 'accept-encoding' # let Net::HTTP handle
      base_headers[k] = v
    end

    # Test 1: Replay exact browser request
    status, data = make_call.call('Test 1: Exact browser replay (search chicken)', search_post_data, base_headers)

    if status == 200
      # Test 2: What's the minimum set of headers needed?
      # Try without cookies
      no_cookie_headers = base_headers.reject { |k, _| k.downcase == 'cookie' }
      s2, _ = make_call.call('Test 2: Without cookies', search_post_data, no_cookie_headers)

      if s2 == 200
        # Try with minimal headers
        minimal_headers = {
          'Content-Type' => 'application/json',
          'Accept' => '*/*',
          'authorization' => base_headers['authorization'],
          'syy-authorization' => base_headers['syy-authorization'],
          'Origin' => 'https://shop.sysco.com',
          'Referer' => 'https://shop.sysco.com/'
        }
        make_call.call('Test 3: Minimal (auth + syy-auth only)', search_post_data, minimal_headers)

        # Try with just Bearer, no syy-authorization
        bearer_only = minimal_headers.reject { |k, _| k.downcase == 'syy-authorization' }
        make_call.call('Test 4: Bearer only (no syy-auth)', search_post_data, bearer_only)

        # Try with just syy-authorization, no Bearer
        syy_only = minimal_headers.reject { |k, _| k.downcase == 'authorization' }
        make_call.call('Test 5: syy-auth only (no Bearer)', search_post_data, syy_only)
      end

      # Test 6: Custom search term (our own query, not replayed)
      puts "\n--- Test 6: Custom query for 'flour' ---"
      custom_body = {
        operationName: 'SearchProducts',
        variables: {
          isBestSellerEnabled: false,
          isUseGraphStockStatusEnabled: true,
          isRebatesPhase2Enabled: false,
          isGuest: false,
          isLocallySourcedEnabled: false,
          params: {
            facets: [],
            q: 'flour',
            start: 0,
            num: 24,
            sort: 'relevance',
            isShowRestrictedItems: false
          }
        },
        query: <<~GQL
          query SearchProducts(
            $params: SearchProductsQuery!
            $isUseGraphStockStatusEnabled: Boolean! = true
            $isBestSellerEnabled: Boolean! = false
            $isGuest: Boolean! = false
            $isLocallySourcedEnabled: Boolean! = false
            $isRebatesPhase2Enabled: Boolean! = false
          ) {
            searchProducts(params: $params) {
              totalResults
              start
              products {
                productId
                name
                brand
                description
                packSize
                splitCode
                sellerId
                siteId
                imageUrl
                stockStatus @include(if: $isUseGraphStockStatusEnabled)
              }
            }
          }
        GQL
      }.to_json

      s6, d6 = make_call.call('Test 6: Custom flour search', custom_body, no_cookie_headers)

      # Test 7: Prices for products found
      if s6 == 200 && d6&.dig('data', 'searchProducts', 'products')&.any?
        products = d6['data']['searchProducts']['products']
        prices_body = {
          operationName: 'Prices',
          variables: {
            isSkipPriceInfo: true,
            isIncludePriceInfoV2: true,
            isIncludeRebateInfo: false,
            isDiscountStructureEnhancementEnabled: false,
            isIncludeSCGP: false,
            isNOIFeatureEnabled: false,
            products: {
              params: products.first(5).map { |p|
                { productId: p['productId'], sellerId: p['sellerId'] || 'USBL',
                  siteId: p['siteId'] || '019', quantity: { case: 0, each: 0 },
                  splitCode: p['splitCode'] || 'CASE' }
              }
            }
          },
          query: <<~GQL
            query Prices(
              $products: PriceInput!
              $isSkipPriceInfo: Boolean! = true
              $isIncludePriceInfoV2: Boolean! = true
              $isIncludeRebateInfo: Boolean! = false
              $isDiscountStructureEnhancementEnabled: Boolean! = false
              $isIncludeSCGP: Boolean! = false
              $isNOIFeatureEnabled: Boolean! = false
            ) {
              prices(products: $products) {
                products {
                  productId
                  priceInfoV2 @include(if: $isIncludePriceInfoV2) {
                    casePrice
                    eachPrice
                    unitPrice
                    catchWeightPrice
                    splitPrices { splitCode price unitPrice }
                  }
                }
              }
            }
          GQL
        }.to_json

        make_call.call('Test 7: Prices for flour products', prices_body, no_cookie_headers)
      end

      # Test 8: GetLists
      puts "\n--- Test 8: GetLists ---"
      lists_body = {
        operationName: 'GetLists',
        variables: {
          shopAccountId: 'usbl-019-707689'
        },
        query: <<~GQL
          query GetLists($shopAccountId: String!) {
            getLists(shopAccountId: $shopAccountId) {
              shopAccountId
              listId
              sellerId
              siteId
              listType
              name
              modifiedAt
              createdAt
              createdBy
              version
              isShared
              permission
              permissionsUpdatedAt
            }
          }
        GQL
      }.to_json

      make_call.call('Test 8: GetLists', lists_body, no_cookie_headers)

      # Test 9: GetOrderHeadersForAccounts (cart/checkout)
      puts "\n--- Test 9: Order Headers ---"
      orders_body = {
        operationName: 'GetOrderHeadersForAccounts',
        variables: {
          shopAccountIds: ['usbl-019-707689']
        },
        query: <<~GQL
          query GetOrderHeadersForAccounts($shopAccountIds: [String!]!) {
            getOrderHeadersForAccounts(shopAccountIds: $shopAccountIds) {
              shopAccountId
              orderHeaders {
                orderId
                orderStatus
                orderDate
                deliveryDate
                totalAmount
                totalItems
              }
            }
          }
        GQL
      }.to_json

      make_call.call('Test 9: GetOrderHeadersForAccounts', orders_body, no_cookie_headers)
    end

    puts "\n=== Done ==="
  end
end
