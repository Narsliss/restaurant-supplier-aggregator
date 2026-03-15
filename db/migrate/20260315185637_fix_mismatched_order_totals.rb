class FixMismatchedOrderTotals < ActiveRecord::Migration[7.1]
  def up
    # Fix orders where total_amount doesn't match the sum of order_items.
    # The previous migration only caught $0 totals. This catches cases where
    # the scraper extracted a wrong value (e.g. a single item price instead
    # of the order total).
    #
    # Only updates orders where the stored total differs from the calculated
    # item total, for non-pending/non-cancelled orders with items.
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
        AND orders.status NOT IN ('pending', 'cancelled')
        AND ROUND(CAST(orders.total_amount AS numeric), 2) != ROUND(CAST(item_totals.calculated_subtotal AS numeric), 2)
    SQL
  end

  def down
    # Not reversible
  end
end
