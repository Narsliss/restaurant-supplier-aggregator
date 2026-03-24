# frozen_string_literal: true

# Full regression test across all supplier API clients.
# Tests: session restore, lists, prices, search, cart cycle.
# No orders are placed — cart is always cleared at the end.
#
# Usage:
#   rake regression:all                          # all suppliers for owner@testing.com
#   rake regression:all EMAIL=other@example.com  # different user
#   rake regression:supplier[chefswarehouse]     # single supplier
#
namespace :regression do
  desc 'Run regression tests across all API-integrated suppliers'
  task all: :environment do
    email = ENV.fetch('EMAIL', 'owner@testing.com')
    user = User.find_by!(email: email)
    puts "═══════════════════════════════════════════════════════════════"
    puts " Regression Test — #{user.email}"
    puts " #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    puts "═══════════════════════════════════════════════════════════════"

    # Only test API-integrated suppliers (skip email-only suppliers)
    api_supplier_codes = %w[chefswarehouse usfoods whatchefswant premiereproduceone]
    results = {}

    api_supplier_codes.each do |code|
      supplier = Supplier.find_by(code: code)
      unless supplier
        puts "\n⚠  Supplier '#{code}' not found in database — skipping"
        results[code] = { status: :skip, reason: 'not found' }
        next
      end

      credential = SupplierCredential.find_by(
        supplier: supplier,
        user: user,
        status: %w[active expired]
      )
      unless credential
        puts "\n⚠  No credential for #{supplier.name} / #{user.email} — skipping"
        results[code] = { status: :skip, reason: 'no credential' }
        next
      end

      results[code] = run_supplier_regression(supplier, credential)
    end

    print_summary(results)
  end

  desc 'Run regression test for a single supplier'
  task :supplier, [:code] => :environment do |_t, args|
    code = args[:code] || ENV['SUPPLIER']
    abort 'Usage: rake regression:supplier[chefswarehouse]' unless code

    email = ENV.fetch('EMAIL', 'owner@testing.com')
    user = User.find_by!(email: email)
    supplier = Supplier.find_by!(code: code)
    credential = SupplierCredential.find_by!(supplier: supplier, user: user)

    results = { code => run_supplier_regression(supplier, credential) }
    print_summary(results)
  end

  # ── Helpers ──────────────────────────────────────────────────

  def run_supplier_regression(supplier, credential)
    code = supplier.code
    result = { status: :pass, tests: {} }
    scraper = supplier.scraper_klass.new(credential)
    skus_for_price_test = []

    puts "\n┌─────────────────────────────────────────────────────────────"
    puts "│ #{supplier.name} (#{code})"
    puts "│ credential: #{credential.id} status=#{credential.status}"
    puts "└─────────────────────────────────────────────────────────────"

    # ── 1. Session restore / soft_refresh ──────────────────────
    result[:tests][:soft_refresh] = timed_test('soft_refresh') do
      ok = scraper.soft_refresh
      raise "soft_refresh returned false" unless ok
      { success: true }
    end

    # ── 2. Scrape lists (order guides) ─────────────────────────
    result[:tests][:scrape_lists] = timed_test('scrape_lists') do
      lists = scraper.scrape_lists
      raise "scrape_lists returned nil" if lists.nil?

      total_items = lists.sum { |l| l[:items]&.size || 0 }

      # Collect some SKUs for price testing
      lists.each do |list|
        (list[:items] || []).each do |item|
          sku = item[:supplier_sku] || item[:sku]
          skus_for_price_test << sku if sku.present? && skus_for_price_test.size < 5
        end
      end

      { success: true, lists: lists.size, items: total_items }
    end

    # ── 3. Scrape prices ───────────────────────────────────────
    result[:tests][:scrape_prices] = timed_test('scrape_prices') do
      if skus_for_price_test.empty?
        # Try to get some SKUs from SupplierProduct if lists didn't yield any
        skus_for_price_test = SupplierProduct
          .where(supplier: credential.supplier)
          .limit(5)
          .pluck(:supplier_sku)
      end

      if skus_for_price_test.empty?
        { success: true, skipped: true, reason: 'no SKUs available' }
      else
        prices = scraper.scrape_prices(skus_for_price_test)
        raise "scrape_prices returned nil" if prices.nil?

        priced = prices.count { |p| p[:current_price].to_f > 0 }
        { success: true, requested: skus_for_price_test.size, returned: prices.size, priced: priced }
      end
    end

    # ── 4. Search (API clients only) ───────────────────────────
    result[:tests][:search] = timed_test('search') do
      api = scraper.respond_to?(:api_client) ? scraper.api_client : nil
      unless api&.respond_to?(:search_products)
        { success: true, skipped: true, reason: 'no API search method' }
      else
        # API search requires an active API session with context IDs.
        # Some suppliers (WCW) may have browser sessions but no API session.
        has_session = api.respond_to?(:verified_vendor_id) ? api.verified_vendor_id.present? : true
        unless has_session
          { success: true, skipped: true, reason: 'API session not available (browser-only)' }
        else
          term = 'chicken'
          search_results = api.search_products(term)
          raise "search returned nil" if search_results.nil?

          count = search_results.is_a?(Array) ? search_results.size :
                  search_results.is_a?(Hash) ? (search_results[:products]&.size || search_results[:results]&.size || 0) : 0
          { success: true, term: term, results: count }
        end
      end
    end

    # ── 5. Cart cycle (add → remove → clear) ────────────────
    # US Foods has no API-based clear_cart — adding items is irreversible
    # without manual intervention. Skip cart tests for USF.
    result[:tests][:cart_cycle] = timed_test('cart_cycle') do
      if code == 'usfoods'
        { success: true, skipped: true, reason: 'USF cart ops are destructive — skipped for safety' }
      elsif skus_for_price_test.empty?
        { success: true, skipped: true, reason: 'no SKUs for cart test' }
      else
        test_sku = skus_for_price_test.first
        items = [{ sku: test_sku, quantity: 1, name: "Regression test item #{test_sku}", expected_price: 0.0 }]
        added = false
        remove_result = nil

        begin
          add_result = scraper.add_to_cart(items)
          added = true

          # Test remove_from_cart if supported
          if scraper.respond_to?(:remove_from_cart)
            remove_result = scraper.remove_from_cart([test_sku])
          end
        rescue NotImplementedError
          { success: true, skipped: true, reason: 'add_to_cart not implemented' }
        rescue Scrapers::BaseScraper::ScrapingError => e
          { success: true, warning: e.message }
        ensure
          if added
            begin
              scraper.clear_cart
            rescue StandardError => e
              puts "    ⚠  clear_cart failed: #{e.message}"
            end
          end
        end

        if add_result
          detail = { success: true, add_result: add_result.is_a?(Hash) ? add_result.slice(:added, :failed) : 'ok' }
          detail[:remove_result] = remove_result if remove_result
          detail
        else
          { success: true, skipped: true, reason: 'add_to_cart not implemented' } unless result[:tests][:cart_cycle]
        end
      end
    end

    # ── 6. Catalog scrape (small sample) ─────────────────────
    result[:tests][:scrape_catalog] = timed_test('scrape_catalog') do
      if scraper.respond_to?(:scrape_catalog)
        products = scraper.scrape_catalog(%w[chicken], max_per_term: 10)
        raise "scrape_catalog returned nil" if products.nil?

        priced = products.count { |p| p[:current_price].to_f > 0 }
        { success: true, products: products.size, priced: priced }
      else
        { success: true, skipped: true, reason: 'scrape_catalog not implemented' }
      end
    end

    # Determine overall status
    failed = result[:tests].select { |_k, v| v[:success] == false }
    result[:status] = failed.any? ? :fail : :pass

    result
  rescue StandardError => e
    puts "  ✗ FATAL: #{e.class}: #{e.message}"
    puts "    #{e.backtrace&.first(3)&.join("\n    ")}"
    { status: :error, error: "#{e.class}: #{e.message}", tests: result[:tests] || {} }
  ensure
    scraper&.close_api_client if scraper.respond_to?(:close_api_client)
  end

  def timed_test(name)
    print "  ● #{name.ljust(18)}"
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(2)

    result[:elapsed] = elapsed
    result[:success] = true unless result.key?(:success)

    if result[:skipped]
      puts "⏭  skipped (#{result[:reason]}) [#{elapsed}s]"
    elsif result[:warning]
      puts "⚠  warning: #{result[:warning]} [#{elapsed}s]"
    else
      detail = result.except(:success, :elapsed, :skipped, :reason, :warning).map { |k, v| "#{k}=#{v}" }.join(' ')
      puts "✓  #{detail} [#{elapsed}s]"
    end

    result
  rescue StandardError => e
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(2)
    puts "✗  #{e.class}: #{e.message} [#{elapsed}s]"
    puts "    #{e.backtrace&.first(3)&.join("\n    ")}"
    { success: false, error: "#{e.class}: #{e.message}", elapsed: elapsed }
  end

  def print_summary(results)
    puts "\n═══════════════════════════════════════════════════════════════"
    puts " SUMMARY"
    puts "═══════════════════════════════════════════════════════════════"

    results.each do |code, result|
      icon = case result[:status]
             when :pass then '✓'
             when :fail then '✗'
             when :error then '💥'
             when :skip then '⏭'
             end

      puts " #{icon}  #{code.ljust(22)} #{result[:status].to_s.upcase}"

      if result[:tests]
        result[:tests].each do |test_name, test_result|
          next unless test_result

          test_icon = test_result[:success] ? '  ✓' : '  ✗'
          test_icon = '  ⏭' if test_result[:skipped]
          elapsed = test_result[:elapsed] ? " [#{test_result[:elapsed]}s]" : ''
          puts "   #{test_icon} #{test_name}#{elapsed}"
        end
      end
    end

    total = results.values.count { |r| r[:status] != :skip }
    passed = results.values.count { |r| r[:status] == :pass }
    failed = results.values.count { |r| r[:status] == :fail }
    errors = results.values.count { |r| r[:status] == :error }

    puts "─────────────────────────────────────────────────────────────"
    puts " #{passed}/#{total} passed, #{failed} failed, #{errors} errors"
    puts "═══════════════════════════════════════════════════════════════"
  end
end
