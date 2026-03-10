class FixOrder39StatusToSubmitted < ActiveRecord::Migration[7.1]
  def up
    order = Order.find_by(id: 39)
    return unless order && order.status == "failed"

    order.update!(
      status: "submitted",
      confirmation_number: "PPO-#{order.created_at.strftime('%Y%m%d')}",
      total_amount: order.calculated_subtotal,
      submitted_at: Time.current,
      error_message: nil
    )
    order.order_items.update_all(status: "added")

    say "Order #39 status updated to 'submitted'"
  end

  def down
    # No-op: one-time data fix
  end
end
