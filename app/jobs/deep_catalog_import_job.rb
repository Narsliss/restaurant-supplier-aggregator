# frozen_string_literal: true

# Deep catalog import for US Foods — browses all food categories and subcategories
# to find products that the fast empty-search import misses.
#
# This takes 1-3 hours and is designed to run as a daily background job.
# Only US Foods supports this (other suppliers don't have category browsing).
#
# Triggered:
#   - Daily at 2 AM via recurring.yml (production only)
#   - Can be run manually: DeepCatalogImportJob.perform_later
class DeepCatalogImportJob < ApplicationJob
  queue_as :scraping

  # No retries — this is a long-running job, retrying would double the time
  discard_on ActiveRecord::RecordNotFound

  def perform
    supplier = Supplier.find_by!(code: 'usfoods')
    credential = find_credential(supplier)

    unless credential
      Rails.logger.warn '[DeepCatalogImport] No active super_admin credential for US Foods, skipping'
      return
    end

    # Skip if a regular import is already running
    if credential.importing?
      Rails.logger.info '[DeepCatalogImport] Regular import already running, skipping deep import'
      return
    end

    # Skip if deep import ran recently (within last 20 hours)
    last_deep = credential.read_attribute(:last_deep_import_at)
    if last_deep.present? && last_deep > 20.hours.ago
      Rails.logger.info "[DeepCatalogImport] Last deep import was #{((Time.current - last_deep) / 3600).round(1)}h ago, skipping"
      return
    end

    Rails.logger.info '[DeepCatalogImport] Starting deep catalog import for US Foods'
    credential.update_columns(
      importing: true,
      import_status_text: 'Deep catalog import: browsing all categories...'
    )

    # Reuse ImportSupplierProductsService for incremental DB writes
    service = ImportSupplierProductsService.new(credential)

    # Pre-load indexes (same as import_catalog does)
    service.instance_variable_set(:@existing_by_sku,
                                  SupplierProduct.where(supplier: supplier).index_by(&:supplier_sku))
    all_products = Product.select(:id, :name, :normalized_name).to_a
    service.instance_variable_set(:@product_index,
                                  service.send(:build_product_index, all_products))
    service.instance_variable_set(:@items_processed, 0)
    service.instance_variable_set(:@seen_skus, Set.new)

    scraper = supplier.scraper_klass.new(credential)

    unless scraper.respond_to?(:scrape_catalog_deep)
      Rails.logger.warn "[DeepCatalogImport] #{supplier.name} scraper doesn't support deep import, skipping"
      return
    end

    total = scraper.scrape_catalog_deep do |batch|
      service.import_batch(batch)
    end

    results = service.results
    Rails.logger.info "[DeepCatalogImport] Complete: #{total} products scraped, #{results[:imported]} new, #{results[:updated]} updated"
  rescue StandardError => e
    Rails.logger.error "[DeepCatalogImport] Failed: #{e.class.name}: #{e.message}"
    Rails.logger.error e.backtrace&.first(10)&.join("\n")
  ensure
    if credential&.persisted?
      attrs = {
        importing: false,
        import_progress: 0,
        import_total: 0,
        import_status_text: nil
      }
      # Only update last_deep_import_at if the column exists
      attrs[:last_deep_import_at] = Time.current if credential.respond_to?(:last_deep_import_at)
      credential.update_columns(attrs)
    end
  end

  private

  def find_credential(supplier)
    super_admin = User.super_admin
    return nil unless super_admin

    cred = super_admin.credential_for(supplier)
    return nil unless cred&.active? || cred&.status == 'pending'

    cred
  end
end
