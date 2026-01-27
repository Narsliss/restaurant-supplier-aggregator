class OrderStatusChannel < ApplicationCable::Channel
  def subscribed
    @order = current_user.orders.find(params[:order_id])
    stream_for @order
  end

  def unsubscribed
    # Cleanup when channel is unsubscribed
  end

  # Class method to broadcast order status updates
  def self.broadcast_status(order)
    broadcast_to(order, {
      type: "status_update",
      order_id: order.id,
      status: order.status,
      confirmation_number: order.confirmation_number,
      total_amount: order.total_amount,
      error_message: order.error_message,
      submitted_at: order.submitted_at&.iso8601
    })
  end

  def self.broadcast_error(order, error_type, error_message, details = {})
    broadcast_to(order, {
      type: "error",
      order_id: order.id,
      error_type: error_type,
      error_message: error_message,
      details: details
    })
  end
end
