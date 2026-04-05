# frozen_string_literal: true

# Verifies the live price of a single newly-added order item in the background.
# Queued when a chef adds an item via "Forgot Something" or minimum suggestions
# on the review page. The existing 3-second polling picks up the result.
#
# SAFETY: This job NEVER submits orders. It only reads one price and updates
# the order_item's verified_price field.
class VerifyItemPriceJob < ApplicationJob
  queue_as :price_verification

  retry_on Ferrum::TimeoutError, wait: 5.seconds, attempts: 2
  retry_on Ferrum::ProcessTimeoutError, wait: 5.seconds, attempts: 2
  discard_on ActiveJob::DeserializationError

  def perform(order_item_id)
    item = OrderItem.includes(:order, supplier_product: :supplier).find_by(id: order_item_id)
    return unless item
    return unless item.supplier_product

    order = item.order
    supplier = order.supplier
    sku = item.supplier_product.supplier_sku
    return unless sku.present?

    # Find credential (same logic as PriceVerificationService)
    statuses = ["active"]
    statuses << "failed" if supplier.password_auth?
    credential = order.user.supplier_credentials
      .where(supplier: supplier)
      .where(status: statuses)
      .order(Arel.sql("CASE status WHEN 'active' THEN 0 ELSE 1 END"))
      .first

    unless credential
      Rails.logger.info "[VerifyItemPrice] No credential for #{supplier.name}, skipping item ##{item.id}"
      return
    end

    scraper = supplier.scraper_klass.new(credential)
    results = scraper.scrape_prices([sku])
    result = results&.first

    if result && result[:current_price]
      item.update!(verified_price: result[:current_price])

      # Update cached price on the supplier product if it changed
      if result[:current_price] != item.supplier_product.current_price
        item.supplier_product.update_price!(result[:current_price], in_stock: result[:in_stock])
      end

      Rails.logger.info "[VerifyItemPrice] Item ##{item.id} (#{sku}): verified at $#{result[:current_price]}"
    else
      Rails.logger.warn "[VerifyItemPrice] Item ##{item.id} (#{sku}): could not verify price"
    end
  rescue Scrapers::BaseScraper::AuthenticationError => e
    Rails.logger.warn "[VerifyItemPrice] Auth failed for #{supplier&.name}: #{e.message}"
  rescue StandardError => e
    Rails.logger.error "[VerifyItemPrice] Error verifying item ##{order_item_id}: #{e.class} - #{e.message}"
  end
end
