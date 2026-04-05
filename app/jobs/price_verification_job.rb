# frozen_string_literal: true

# Verifies live supplier prices for a single order on the review page.
# One job per order (one browser session per supplier).
#
# Flow:
#   Review page loads → PriceVerificationJob per order → marks order as verified/price_changed/failed
#   User reviews verified prices → clicks Submit → PlaceOrderJob
#
# SAFETY: This job NEVER calls submit!, PlaceOrderJob, or any scraper ordering code.
# It only verifies prices and updates the order status for user review.
class PriceVerificationJob < ApplicationJob
  queue_as :price_verification

  retry_on Ferrum::TimeoutError, wait: 10.seconds, attempts: 2
  retry_on Ferrum::ProcessTimeoutError, wait: 10.seconds, attempts: 2
  discard_on ActiveJob::DeserializationError

  def perform(order_id, options = {})
    order = Order.find_by(id: order_id)
    return unless order

    # Demo mode: skip verification (same as email suppliers)
    if ENV['DEMO_MODE'] == 'true'
      order.update!(verification_status: 'skipped')
      Rails.logger.info "[PriceVerificationJob] Order ##{order_id} skipped — demo mode"
      return
    end

    # Guard: only verify orders that are in "verifying" state
    unless order.verifying?
      Rails.logger.info "[PriceVerificationJob] Order ##{order_id} is #{order.status}, skipping."
      return
    end

    service = Orders::PriceVerificationService.new(order)
    result = service.verify!

    # Store delivery address if extracted during verification
    if result[:delivery_address].present?
      order.update!(supplier_delivery_address: result[:delivery_address])
      Rails.logger.info "[PriceVerificationJob] Order ##{order_id} delivery address: #{result[:delivery_address]}"
    end

    if result[:success]
      case result[:verification_status]
      when "verified", "skipped"
        # Prices match (or scraper doesn't support verification) — save as draft
        Rails.logger.info "[PriceVerificationJob] Order ##{order_id} verified. Saved as draft."
        order.mark_as_draft!
      when "price_changed"
        # Price changes detected — user needs to review on the review page
        Rails.logger.info "[PriceVerificationJob] Order ##{order_id} has price changes. Holding for user review."
        # Status already set to "price_changed" by the service
      end
    else
      # Verification failed — hold for user action
      Rails.logger.warn "[PriceVerificationJob] Order ##{order_id} verification failed: #{result[:error]}"
      # Order stays in current state with verification_status = "failed"
      # User can retry or skip verification from the review page
    end
  end
end
