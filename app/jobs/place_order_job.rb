class PlaceOrderJob < ApplicationJob
  queue_as :critical

  discard_on ActiveRecord::RecordNotFound

  def perform(order_id, options = {})
    order = Order.find(order_id)

    Rails.logger.info "[PlaceOrderJob] Processing order #{order.id} for #{order.supplier.name}"

    service = Orders::OrderPlacementService.new(order)
    result = service.place_order(
      accept_price_changes: options[:accept_price_changes] || false,
      skip_warnings: options[:skip_warnings] || false
    )

    if result[:success]
      # Send success notification
      OrderMailer.order_confirmed(order).deliver_later
      
      Rails.logger.info "[PlaceOrderJob] Order #{order.id} placed successfully"
    else
      handle_failure(order, result)
    end
  rescue => e
    Rails.logger.error "[PlaceOrderJob] Order #{order_id} failed: #{e.message}"
    
    order.update!(status: "failed", error_message: e.message)
    OrderMailer.order_failed(order, e.message).deliver_later
    
    raise # Re-raise for retry logic
  end

  private

  def handle_failure(order, result)
    case result[:error_type]
    when "2fa_required"
      Rails.logger.info "[PlaceOrderJob] Order #{order.id} waiting for 2FA"
      # User has already been notified via ActionCable
    when "price_changed"
      Rails.logger.info "[PlaceOrderJob] Order #{order.id} requires price review"
      OrderMailer.price_change_review(order, result[:details][:price_changes]).deliver_later
    when "captcha"
      Rails.logger.warn "[PlaceOrderJob] Order #{order.id} blocked by CAPTCHA"
      OrderMailer.manual_intervention_required(order, "CAPTCHA detected").deliver_later
    when "account_hold"
      Rails.logger.warn "[PlaceOrderJob] Order #{order.id} blocked by account hold"
      OrderMailer.account_hold_notification(order).deliver_later
    else
      Rails.logger.error "[PlaceOrderJob] Order #{order.id} failed: #{result[:error]}"
      OrderMailer.order_failed(order, result[:error]).deliver_later
    end
  end
end
