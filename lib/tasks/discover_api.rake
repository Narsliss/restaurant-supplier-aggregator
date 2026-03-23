# frozen_string_literal: true

namespace :discover_api do
  desc 'Capture API traffic from a supplier site'
  task :capture, [:supplier] => :environment do |_t, args|
    require 'json'

    supplier_code = args[:supplier] || ENV['SUPPLIER']
    abort 'Usage: rake discover_api:capture[us_foods]' unless supplier_code

    browse_time = ENV.fetch('BROWSE_TIME', '180').to_i

    supplier = Supplier.find_by(code: supplier_code) || Supplier.where('name ILIKE ?', "%#{supplier_code}%").first
    abort "Supplier '#{supplier_code}' not found" unless supplier

    credential = supplier.supplier_credentials.where(status: %w[active expired]).first
    base_url = supplier.base_url || supplier.login_url || ''
    domain = URI.parse(base_url).host rescue supplier_code

    puts "=" * 80
    puts "API Discovery: #{supplier.name}"
    puts "Domain: #{domain}"
    puts "Credential: #{credential&.username || 'none'}"
    puts "Browse time: #{browse_time}s"
    puts "=" * 80
    puts "\nOpening browser. Log in and browse around."
    puts "Timer starts now.\n\n"

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
      # Skip static assets and common trackers
      next if url.match?(/\.(jpg|jpeg|png|gif|webp|svg|ico|woff|woff2|ttf|eot|css)(\?|$)/i)
      next if url.match?(/adobedtm|google-analytics|googletagmanager|doubleclick|facebook\.com\/tr/i)

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

    # Navigate to supplier site
    start_url = base_url.presence || "https://#{domain}"
    browser.go_to(start_url)

    browse_time.times do |i|
      remaining = browse_time - i
      if remaining % 30 == 0 && remaining > 0
        puts "[#{remaining}s] Requests captured: #{api_requests.size}"
      end
      sleep 1
    end

    # Capture auth state
    cookies = begin
      browser.cookies.all
    rescue StandardError
      {}
    end

    local_storage = begin
      browser.evaluate('(function(){var i={};for(var k=0;k<localStorage.length;k++){var key=localStorage.key(k);i[key]=localStorage.getItem(key)}return i})()')
    rescue StandardError
      {}
    end

    browser&.quit

    # Build results
    all_calls = api_requests.map do |req_id, req|
      resp = api_responses[req_id] || {}
      {
        method: req[:method],
        url: req[:url],
        status: resp[:status],
        mime_type: resp[:mime_type],
        request_headers: req[:headers],
        post_data: req[:post_data],
        response_body: resp[:body],
        response_size: resp[:body_size]
      }
    end

    # Filter to JSON/API responses from the supplier domain
    interesting = all_calls.select do |call|
      url = call[:url] || ''
      mime = call[:mime_type] || ''
      (url.include?(domain.to_s) || url.include?('api') || url.include?('graphql')) &&
        (mime.include?('json') || mime.include?('graphql') ||
         url.include?('/api/') || url.include?('graphql') ||
         (call[:response_body] && call[:response_body].to_s.match?(/\A[\[{]/)))
    end

    puts "\n#{'=' * 80}"
    puts "RESULTS: #{all_calls.size} total requests, #{interesting.size} JSON/API"
    puts "=" * 80

    # Summary of all requests by domain
    by_domain = all_calls.group_by { |c| URI.parse(c[:url]).host rescue 'unknown' }
    puts "\nRequests by domain:"
    by_domain.sort_by { |_, v| -v.size }.each do |d, calls|
      puts "  #{d}: #{calls.size}"
    end

    # Show interesting API calls
    puts "\n## API/JSON Responses (#{interesting.size})"
    puts "-" * 80
    interesting.each_with_index do |call, i|
      puts "\n#{i + 1}. #{call[:method]} #{call[:url][0..120]}"
      puts "   Status: #{call[:status]} | Size: #{call[:response_size]} | Type: #{call[:mime_type]}"
      if call[:post_data]
        puts "   Request:"
        begin
          puts "   #{JSON.pretty_generate(JSON.parse(call[:post_data]))[0..500]}"
        rescue StandardError
          puts "   #{call[:post_data][0..500]}"
        end
      end
      if call[:response_body]
        puts "   Response:"
        begin
          puts "   #{JSON.pretty_generate(JSON.parse(call[:response_body]))[0..800]}"
        rescue StandardError
          puts "   #{call[:response_body][0..500]}"
        end
      end
    end

    # Auth analysis
    puts "\n#{'=' * 80}"
    puts "AUTH ANALYSIS"
    puts "=" * 80
    puts "\nAuth-related cookies:"
    cookies.each do |name, cookie|
      val = cookie.value.to_s rescue cookie.to_s
      if name.to_s.match?(/auth|token|session|jwt|bearer|user|login|id_token|access_token/i)
        puts "  *** #{name}: #{val[0..80]}"
      end
    end

    puts "\nAuth-related localStorage:"
    (local_storage || {}).each do |key, value|
      if key.match?(/auth|token|session|jwt|bearer|user|login|id_token|access_token|msal/i)
        puts "  *** #{key}: #{value.to_s[0..120]}"
      end
    end

    puts "\nAuth headers in requests:"
    all_calls.each do |call|
      next unless call[:request_headers]
      call[:request_headers].each do |k, v|
        next if k.downcase == ':authority'
        if k.downcase.match?(/auth|token|bearer|x-csrf|x-xsrf|ocp-apim/)
          puts "  #{k}: #{v.to_s[0..120]}"
        end
      end
    end

    # Save results
    output_file = Rails.root.join('tmp', "#{supplier_code}_api_discovery.json")
    File.write(output_file, JSON.pretty_generate({
      supplier: supplier.name,
      timestamp: Time.current.iso8601,
      total_requests: all_calls.size,
      api_responses: interesting.size,
      all_requests: all_calls.map { |c| c.except(:response_body, :request_headers) },
      api_details: interesting,
      cookies: cookies.transform_values { |c| { value: (c.value rescue c.to_s), domain: (c.domain rescue nil) } },
      local_storage: local_storage
    }))
    puts "\n\nSaved to: #{output_file}"
  end
end
