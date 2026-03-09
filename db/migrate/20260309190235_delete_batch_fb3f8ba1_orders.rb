class DeleteBatchFb3f8ba1Orders < ActiveRecord::Migration[7.1]
  def up
    # Delete order items first (foreign key), then orders
    execute <<~SQL
      DELETE FROM order_items
      WHERE order_id IN (
        SELECT id FROM orders WHERE batch_id = 'fb3f8ba1-f907-4ddd-92d2-803ada3675bd'
      )
    SQL

    execute <<~SQL
      DELETE FROM orders
      WHERE batch_id = 'fb3f8ba1-f907-4ddd-92d2-803ada3675bd'
    SQL
  end

  def down
    # One-time data cleanup
  end
end
