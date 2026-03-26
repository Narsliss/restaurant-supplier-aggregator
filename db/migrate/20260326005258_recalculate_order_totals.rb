class RecalculateOrderTotals < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      UPDATE orders SET
        subtotal = (
          SELECT COALESCE(SUM(line_total), 0)
          FROM order_items
          WHERE order_items.order_id = orders.id
        ),
        total_amount = (
          SELECT COALESCE(SUM(line_total), 0)
          FROM order_items
          WHERE order_items.order_id = orders.id
        ) + COALESCE(tax, 0)
    SQL
  end

  def down
    # No-op: cannot restore previous incorrect totals
  end
end
