# frozen_string_literal: true

class QuickPriceUpdateService
  attr_reader :organization, :results

  # High-volume search terms most likely to have price changes
  QUICK_SEARCH_TERMS = %w[
    chicken beef pork salmon
    cheese butter milk eggs
    oil flour rice pasta
    tomato onion potato lettuce
    coffee juice
  ].freeze

  def initialize(organization)
    @organization = organization
    @results = { updated: 0, errors: [], duration: 0 }
  end

  # Quick price update for all active suppliers (target: <15 minutes, runs every 30 minutes)
  def update_all_suppliers
    start_time = Time.current
    Rails.logger.info "[QuickPriceUpdate] Starting price update for organization #{organization.id}"

    # Get all active credentials for this organization
    credentials = organization.supplier_credentials.active.includes(:supplier)

    if credentials.empty?
      Rails.logger.info '[QuickPriceUpdate] No active credentials found'
      return results
    end

    Rails.logger.info "[QuickPriceUpdate] Found #{credentials.count} active credentials"

    # Run updates in parallel using threads
    # Each supplier gets its own browser instance
    threads = credentials.map do |credential|
      Thread.new do
        update_supplier(credential)
      rescue StandardError => e
        Rails.logger.error "[QuickPriceUpdate] Thread error for #{credential.supplier.name}: #{e.message}"
        { supplier: credential.supplier.name, error: e.message }
      end
    end

    # Wait for all threads to complete (with timeout)
    thread_results = threads.map do |t|
      t.join(300) # 5 minute timeout per supplier
      t.value if t.alive? == false
    end.compact

    # Aggregate results
    thread_results.each do |r|
      if r.is_a?(Hash) && r[:error]
        results[:errors] << r[:error]
      elsif r.is_a?(Integer)
        results[:updated] += r
      end
    end

    results[:duration] = Time.current - start_time
    Rails.logger.info "[QuickPriceUpdate] Completed in #{results[:duration].round(2)}s. Updated #{results[:updated]} prices."

    results
  end

  private

  def update_supplier(credential)
    supplier = credential.supplier
    Rails.logger.info "[QuickPriceUpdate] Updating #{supplier.name}"

    # Use only top 5 search terms for speed
    search_terms = QUICK_SEARCH_TERMS.first(5)

    scraper = supplier.scraper_klass.new(credential)

    # Quick scrape - only search, no categories
    catalog_items = scraper.scrape_catalog(search_terms, max_per_term: 20)

    Rails.logger.info "[QuickPriceUpdate] #{supplier.name}: Found #{catalog_items.size} items"

    # Get existing products for this supplier
    existing_skus = SupplierProduct.where(supplier: supplier).pluck(:supplier_sku).to_set

    # Only update existing products (skip new product creation for speed)
    updated_count = 0
    catalog_items.each do |item|
      next unless existing_skus.include?(item[:supplier_sku])
      next unless item[:current_price].present?

      # Update price directly (skip matching/normalization)
      supplier_product = SupplierProduct.find_by(
        supplier: supplier,
        supplier_sku: item[:supplier_sku]
      )

      if supplier_product && supplier_product.current_price != item[:current_price]
        supplier_product.update_price!(item[:current_price], in_stock: item[:in_stock])
        updated_count += 1
      end
    end

    Rails.logger.info "[QuickPriceUpdate] #{supplier.name}: Updated #{updated_count} prices"
    updated_count
  rescue Scrapers::BaseScraper::AuthenticationError => e
    Rails.logger.error "[QuickPriceUpdate] Auth failed for #{supplier.name}: #{e.message}"
    credential.mark_failed!(e.message)
    { error: "#{supplier.name}: Authentication failed" }
  rescue StandardError => e
    Rails.logger.error "[QuickPriceUpdate] Error for #{supplier.name}: #{e.message}"
    { error: "#{supplier.name}: #{e.message}" }
  end
end
