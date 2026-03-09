class DeleteAllDryRunOrders < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      DELETE FROM order_items
      WHERE order_id IN (
        SELECT id FROM orders WHERE confirmation_number LIKE 'DRY-RUN-%'
      )
    SQL

    execute <<~SQL
      DELETE FROM orders
      WHERE confirmation_number LIKE 'DRY-RUN-%'
    SQL
  end

  def down
    # One-time data cleanup
  end
end
