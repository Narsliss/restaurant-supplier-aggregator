# frozen_string_literal: true

namespace :sysco do
  desc 'Test Sysco cart: create draft order, add items, verify, then delete (no order placed)'
  task test_cart: :environment do
    supplier = Supplier.find_by(code: 'sysco')
    abort 'Sysco supplier not found in database' unless supplier

    credential = supplier.supplier_credentials.find_by(status: 'active')
    credential ||= supplier.supplier_credentials.where(status: %w[expired]).first
    abort 'No Sysco credential found. Add one via the UI first.' unless credential

    puts "=" * 60
    puts "Sysco Cart Test"
    puts "Credential: #{credential.username} (#{credential.status})"
    puts "=" * 60

    scraper = Scrapers::SyscoScraper.new(credential)

    # Resolve test SKUs: ENV override or pull from existing catalog
    skus = if ENV['SKUS'].present?
             ENV['SKUS'].split(',').map(&:strip)
           else
             puts "\nNo SKUS env var — picking from existing SupplierProducts..."
             existing = SupplierProduct.where(supplier: supplier, in_stock: true)
                                       .where.not(supplier_sku: [nil, ''])
                                       .order(updated_at: :desc)
                                       .limit(3)
                                       .pluck(:supplier_sku, :supplier_name, :current_price)
             if existing.empty?
               puts "No existing Sysco products in DB. Running a quick catalog search..."
               products = []
               scraper.scrape_catalog(['chicken'], max_per_term: 3) { |batch| products.concat(batch) }
               abort 'Catalog search returned no products' if products.empty?
               products.map { |p| p[:supplier_sku] }
             else
               puts "Found #{existing.size} products in DB:"
               existing.each { |sku, name, price| puts "  #{sku} — #{name} ($#{price})" }
               existing.map(&:first)
             end
           end

    abort 'No SKUs to test with' if skus.empty?

    # Build cart items (qty 1 each, price from DB or 0)
    items = skus.map do |sku|
      sp = SupplierProduct.find_by(supplier: supplier, supplier_sku: sku)
      {
        sku: sku,
        name: sp&.supplier_name || "SKU #{sku}",
        quantity: 1,
        expected_price: sp&.current_price || 0.0
      }
    end

    puts "\n--- Step 1: add_to_cart (#{items.size} items) ---"
    items.each { |i| puts "  #{i[:sku]} — #{i[:name]} (qty #{i[:quantity]})" }

    begin
      result = scraper.add_to_cart(items)
      puts "\nResult: #{result[:added]} added, #{result[:failed]&.size || 0} failed"
      puts "Order ID: #{result[:order_id]}" if result[:order_id]
      if result[:failed]&.any?
        puts "Failed items:"
        result[:failed].each { |f| puts "  #{f[:sku]}: #{f[:error]}" }
      end

      # --- Step 2: Test removing a single item via qty=0 ---
      if items.size >= 2
        remove_sku = items.first[:sku]
        puts "\n--- Step 2: Remove single item (SKU #{remove_sku}) via qty=0 ---"

        tokens = scraper.send(:load_api_tokens)
        order_id = scraper.instance_variable_get(:@last_sysco_order_id)
        seq_id = scraper.instance_variable_get(:@last_sysco_sequence_id)

        remove_line = [{
          qty: 0,
          soldAs: 'cs',
          productId: remove_sku.to_s,
          pricingType: 'N',
          price: 0,
          totalPrice: 0,
          commissionBasis: 0,
          siteId: tokens[:site_id],
          sellerId: tokens[:seller_id]
        }]

        begin
          updated = scraper.send(:graphql_update_order,
            order_id: order_id,
            sequence_id: seq_id,
            line_items: remove_line
          )
          remaining = updated['lineItems'] || []
          remaining_skus = remaining.map { |li| li['productId'] }
          removed = !remaining_skus.include?(remove_sku.to_s)

          puts "After qty=0 update:"
          puts "  Total items: #{updated['totalLineItems']}"
          puts "  Total price: #{updated['totalPrice']}"
          puts "  Remaining SKUs: #{remaining_skus.join(', ')}"
          puts "  SKU #{remove_sku} removed? #{removed ? 'YES' : 'NO — still on order'}"

          # Update sequence_id for cleanup
          scraper.instance_variable_set(:@last_sysco_sequence_id, updated['sequenceId'])
        rescue => e
          puts "  qty=0 removal FAILED: #{e.class} — #{e.message}"
          puts "  (Item removal may require a different approach)"
        end
      else
        puts "\n--- Step 2: Skipped (need 2+ items to test individual removal) ---"
      end

      puts "\n--- Step 3: clear_cart (delete draft order) ---"
      scraper.clear_cart
      puts "Draft order deleted."

      puts "\n#{'=' * 60}"
      puts "SUCCESS — cart round-trip complete, no order placed."
      puts "=" * 60
    rescue => e
      puts "\nERROR: #{e.class} — #{e.message}"
      puts e.backtrace.first(5).join("\n")

      # Attempt cleanup
      puts "\nAttempting cleanup..."
      begin
        scraper.clear_cart
        puts "Cleanup: draft order deleted."
      rescue => cleanup_err
        puts "Cleanup failed: #{cleanup_err.message}"
      end

      exit 1
    end
  end
end
