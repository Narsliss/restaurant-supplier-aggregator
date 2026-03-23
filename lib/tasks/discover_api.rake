# frozen_string_literal: true

namespace :discover_api do
  desc 'Capture CW cart/add API request'
  task chefs_warehouse: :environment do
    require 'json'

    browse_time = ENV.fetch('BROWSE_TIME', '120').to_i

    puts "=" * 80
    puts "CW Cart API Discovery"
    puts "=" * 80
    puts "\nOpening browser. Please:"
    puts "  1. Log in if needed"
    puts "  2. Go to your order guide"
    puts "  3. Add 1 item to cart"
    puts "  4. Wait for timer (#{browse_time}s)"
    puts ""

    browser = Ferrum::Browser.new(
      headless: false,
      timeout: 120,
      process_timeout: 30,
      window_size: [1920, 1080],
      browser_options: { "no-sandbox": true },
      browser_path: ENV['BROWSER_PATH'].presence
    )

    api_requests = {}
    api_responses = {}
    mutex = Mutex.new

    page = browser.page
    page.command('Network.enable', maxResourceBufferSize: 10_000_000, maxTotalBufferSize: 50_000_000)

    page.on('Network.requestWillBeSent') do |params|
      url = params['request']['url']
      next unless url.include?('chefswarehouse.com')
      next if url.match?(/\.(jpg|jpeg|png|gif|webp|svg|ico|woff|woff2|ttf|eot|css|js)(\?|$)/i)
      next if url.match?(/\/(media|transform|asset)\//i)
      # Focus on cart and product endpoints
      next unless url.include?('cart') || url.include?('web-api') || url.include?('order-guide')

      mutex.synchronize do
        api_requests[params['requestId']] = {
          method: params['request']['method'],
          url: url,
          headers: params['request']['headers'],
          post_data: params['request']['postData'],
          timestamp: params['timestamp']
        }
      end
    end

    page.on('Network.responseReceived') do |params|
      request_id = params['requestId']
      mutex.synchronize do
        next unless api_requests[request_id]
        api_responses[request_id] = {
          status: params['response']['status'],
          headers: params['response']['headers'],
          mime_type: params['response']['mimeType']
        }
      end
    end

    page.on('Network.loadingFinished') do |params|
      request_id = params['requestId']
      mutex.synchronize do
        next unless api_requests[request_id]
        begin
          result = page.command('Network.getResponseBody', requestId: request_id)
          api_responses[request_id] ||= {}
          api_responses[request_id][:body] = (result['body'] || '')[0..10_000]
          api_responses[request_id][:body_size] = (result['body'] || '').length
        rescue StandardError
        end
      end
    end

    browser.go_to('https://www.chefswarehouse.com/login')

    browse_time.times do |i|
      remaining = browse_time - i
      if remaining % 15 == 0 && remaining > 0
        cart_reqs = api_requests.count { |_, r| r[:url].include?('cart') }
        puts "[#{remaining}s] Requests: #{api_requests.size} (cart: #{cart_reqs})"
      end
      sleep 1
    end

    browser&.quit

    # Show results focused on cart operations
    all_calls = api_requests.map do |req_id, req|
      resp = api_responses[req_id] || {}
      { method: req[:method], url: req[:url], post_data: req[:post_data],
        status: resp[:status], body: resp[:body], body_size: resp[:body_size] }
    end

    cart_calls = all_calls.select { |c| c[:url].include?('cart') }

    puts "\n#{'=' * 80}"
    puts "CART API CALLS (#{cart_calls.size})"
    puts "=" * 80

    cart_calls.each_with_index do |call, i|
      puts "\n#{i + 1}. #{call[:method]} #{call[:url]}"
      puts "   Status: #{call[:status]}"
      if call[:post_data]
        puts "   Request Body:"
        begin
          puts "   " + JSON.pretty_generate(JSON.parse(call[:post_data]))[0..2000]
        rescue
          puts "   " + call[:post_data][0..2000]
        end
      end
      if call[:body]
        puts "   Response (#{call[:body_size]} bytes):"
        begin
          puts "   " + JSON.pretty_generate(JSON.parse(call[:body]))[0..1000]
        rescue
          puts "   " + call[:body][0..500]
        end
      end
    end

    # Save full results
    output_file = Rails.root.join('tmp', 'cw_cart_discovery.json')
    File.write(output_file, JSON.pretty_generate({ cart_calls: cart_calls, all_calls: all_calls }))
    puts "\n\nSaved to: #{output_file}"
  end
end
