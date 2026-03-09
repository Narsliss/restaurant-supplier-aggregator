class ResetBatchFb3f8ba1Final < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      UPDATE orders
      SET status = 'pending',
          error_message = NULL,
          confirmation_number = NULL,
          submitted_at = NULL
      WHERE batch_id = 'fb3f8ba1-f907-4ddd-92d2-803ada3675bd'
    SQL

    execute <<~SQL
      UPDATE order_items
      SET status = 'pending'
      WHERE order_id IN (
        SELECT id FROM orders WHERE batch_id = 'fb3f8ba1-f907-4ddd-92d2-803ada3675bd'
      )
    SQL
  end

  def down
    # One-time data fix
  end
end
