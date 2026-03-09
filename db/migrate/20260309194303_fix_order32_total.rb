class FixOrder32Total < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      UPDATE orders
      SET total_amount = (
        SELECT COALESCE(SUM(line_total), 0)
        FROM order_items
        WHERE order_items.order_id = orders.id
      ),
      subtotal = (
        SELECT COALESCE(SUM(line_total), 0)
        FROM order_items
        WHERE order_items.order_id = orders.id
      )
      WHERE id = 32
    SQL
  end

  def down
    # One-time data fix
  end
end
