# frozen_string_literal: true

# Prices Chef's Warehouse catalog items that have no price (Oct 2026). The CW
# catalog import has stored `current_price: nil` since the Mar 23 API rewrite,
# and catalog search hides unpriced items — 13,444 of 15,624 CW products were
# invisible to chefs. See docs/cw-catalog-pricing.md.
#
# MANUAL ONLY for now (Carmin: run it once by hand and check it before it goes
# on a schedule). From a production console:
#
#   ChefsWarehouseCatalogPricingJob.perform_now(limit: 200)              # small first run
#   ChefsWarehouseCatalogPricingJob.perform_now(dry_run: true)           # price, don't save
#   ChefsWarehouseCatalogPricingJob.perform_now                          # every unpriced item
#   ChefsWarehouseCatalogPricingJob.perform_now(scope: 'all')            # re-price everything
#
# Writes only the catalog product (price, piece price, timestamps). Never
# touches stock flags, carts or orders. Returns a summary hash and logs it.
class ChefsWarehouseCatalogPricingJob < ApplicationJob
  queue_as :scraping

  BATCH = 10 # SKUs per /product/prices call (x2 business units = 20 variants)
  SAMPLE_SIZE = 12

  def perform(scope: 'unpriced', limit: nil, dry_run: false, credential_id: nil)
    supplier = Supplier.find_by(code: 'chefswarehouse')
    credential = credential_id ? SupplierCredential.find(credential_id) : pricing_credential(supplier)
    raise 'No active Chef\'s Warehouse credential to price with' unless credential

    products = SupplierProduct.where(supplier: supplier, discontinued: false)
    products = products.where(current_price: nil) if scope.to_s == 'unpriced'
    products = products.order(:id)
    products = products.limit(limit) if limit

    scraper = Scrapers::ChefsWarehouseScraper.new(credential)
    scraper.api_client.ensure_session!

    stats = Hash.new(0)
    samples = []
    started = Time.current

    products.in_batches(of: BATCH) do |batch|
      rows = batch.to_a
      prices = begin
        scraper.catalog_prices(rows.map(&:supplier_sku), pack_sizes: rows.to_h { |sp| [sp.supplier_sku, sp.pack_size] })
      rescue StandardError => e
        stats[:batch_errors] += 1
        Rails.logger.warn "[CWCatalogPricing] batch failed: #{e.class}: #{e.message}"
        next
      end

      rows.each do |sp|
        stats[:checked] += 1
        found = prices[sp.supplier_sku]
        unless found
          stats[:not_priced] += 1
          next
        end

        stats[:"bu_#{found[:business_unit]}"] += 1
        stats[:with_piece_price] += 1 if found[:piece_price]
        samples << sample_row(sp, found) if samples.size < SAMPLE_SIZE && (stats[:checked] % 7).zero?

        next if dry_run

        sp.update!(
          previous_price: sp.current_price,
          current_price: found[:price],
          piece_price: found[:piece_price],
          piece_pack_size: found[:piece_pack_size],
          price_updated_at: Time.current,
          last_scraped_at: Time.current
        )
        stats[:saved] += 1
      end
    end

    summary = {
      scope: scope, dry_run: dry_run, credential: credential.user&.email,
      minutes: ((Time.current - started) / 60.0).round(1),
      **stats.to_h,
      still_unpriced_in_catalog: SupplierProduct.where(supplier: supplier, discontinued: false, current_price: nil).count,
      samples: samples
    }
    Rails.logger.warn "[CWCatalogPricing] #{summary.except(:samples).inspect}"
    summary
  end

  private

  def sample_row(sp, found)
    { sku: sp.supplier_sku, name: sp.supplier_name, pack: sp.pack_size, price: found[:price],
      piece_price: found[:piece_price], business_unit: found[:business_unit],
      check_at: "https://www.chefswarehouse.com/products/#{sp.supplier_sku}/" }
  end

  # Same pick as the catalog import (StaggeredSupplierImportJob): an active
  # login with a live session, most recently used.
  def pricing_credential(supplier)
    creds = SupplierCredential.where(supplier: supplier, status: 'active').to_a
    with_session = creds.select(&:session_valid?)
    (with_session.presence || creds).max_by { |c| c.last_login_at || c.created_at }
  end
end
