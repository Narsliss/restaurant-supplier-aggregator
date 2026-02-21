# frozen_string_literal: true

# Safety-net job that discontinues products which have not been seen in any
# supplier scrape for an extended period. This catches edge cases where the
# import service's per-run miss tracking didn't complete (e.g., crash mid-diff)
# or products that pre-date the miss tracking feature.
#
# Products are only discontinued if BOTH conditions are true:
#   1. last_scraped_at is older than the staleness threshold (default 72 hours)
#   2. consecutive_misses >= SupplierProduct::DISCONTINUE_AFTER_MISSES
#
# This double-check prevents discontinuing products that are simply on a
# supplier with infrequent imports.
class DiscontinueStaleProductsJob < ApplicationJob
  queue_as :low

  # Products not scraped within this window AND with enough misses get discontinued.
  # Set to 7 days because platform catalog imports now run daily (not hourly) and
  # list syncing is the primary data source — products need time to appear in either.
  STALENESS_THRESHOLD = 7.days

  def perform
    Rails.logger.info '[DiscontinueStaleProducts] Checking for stale products to discontinue'

    candidates = SupplierProduct
                 .where(discontinued: false)
                 .where('consecutive_misses >= ?', SupplierProduct::DISCONTINUE_AFTER_MISSES)
                 .where('last_scraped_at < ? OR last_scraped_at IS NULL', STALENESS_THRESHOLD.ago)

    count = candidates.count

    if count.zero?
      Rails.logger.info '[DiscontinueStaleProducts] No stale products found'
      return
    end

    Rails.logger.info "[DiscontinueStaleProducts] Discontinuing #{count} stale products"

    candidates.find_each do |product|
      product.update!(
        discontinued: true,
        discontinued_at: Time.current,
        in_stock: false
      )
      Rails.logger.info "[DiscontinueStaleProducts] Discontinued #{product.supplier_name} " \
                        "(SKU: #{product.supplier_sku}, supplier: #{product.supplier.name}, " \
                        "last scraped: #{product.last_scraped_at&.iso8601 || 'never'}, " \
                        "misses: #{product.consecutive_misses})"
    end

    Rails.logger.info "[DiscontinueStaleProducts] Done — #{count} products discontinued"
  end
end
