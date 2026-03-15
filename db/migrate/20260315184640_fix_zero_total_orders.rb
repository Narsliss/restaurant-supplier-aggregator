class FixZeroTotalOrders < ActiveRecord::Migration[7.1]
  def up
    # Fix orders where total_amount was incorrectly stored as 0 or NULL
    # due to scrapers returning 0 when they couldn't parse the supplier's total.
    # Recalculate from order_items.line_total (source of truth).
    execute <<~SQL
      UPDATE orders
      SET subtotal = item_totals.calculated_subtotal,
          total_amount = item_totals.calculated_subtotal
      FROM (
        SELECT order_id, SUM(line_total) AS calculated_subtotal
        FROM order_items
        GROUP BY order_id
        HAVING SUM(line_total) > 0
      ) AS item_totals
      WHERE orders.id = item_totals.order_id
        AND (orders.total_amount IS NULL OR orders.total_amount = 0)
        AND orders.status NOT IN ('pending', 'cancelled')
    SQL
  end

  def down
    # Not reversible — we don't know which orders originally had legitimate $0 totals
    # (there shouldn't be any for non-pending orders with items)
  end
end
