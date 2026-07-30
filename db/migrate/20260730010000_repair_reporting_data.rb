# Data repair for two reporting bugs found 2026-07-29:
#
# 1. Order items created through the order builder were bulk-inserted, which
#    skips the snapshot_product_info callback — product_name/product_sku were
#    NULL. Reports group by product_name, so every nameless item collapsed into
#    a single blank row (123 distinct products in one row for one location).
#    The insert path now sets both columns; this backfills existing rows.
#
# 2. savings_amount is written once at order creation and never revisited, so a
#    bad cross-unit comparison stayed frozen forever (order #80: $4,738.37
#    "saved" on $233.80 spent). Recompute any order whose stored savings is
#    implausible against the now-guarded Order#calculate_savings.
class RepairReportingData < ActiveRecord::Migration[7.1]
  def up
    backfill_item_names
    repair_implausible_savings
  end

  def down
    # Data repair only — nothing to undo (the previous values were wrong).
  end

  private

  def backfill_item_names
    updated = execute(<<~SQL).cmd_tuples
      UPDATE order_items
      SET product_name = COALESCE(NULLIF(order_items.product_name, ''), supplier_products.supplier_name),
          product_sku  = COALESCE(NULLIF(order_items.product_sku, ''), supplier_products.supplier_sku)
      FROM supplier_products
      WHERE supplier_products.id = order_items.supplier_product_id
        AND (order_items.product_name IS NULL OR order_items.product_name = ''
             OR order_items.product_sku IS NULL OR order_items.product_sku = '')
    SQL

    say "Backfilled product name/sku on #{updated} order items"
  end

  def repair_implausible_savings
    repaired = 0

    Order.where.not(savings_amount: nil)
         .where("savings_amount > 0")
         .includes(order_items: :supplier_product)
         .find_each do |order|
      spent = order.total_amount.to_f
      stored = order.savings_amount.to_f
      # Only touch orders whose stored savings is implausible for what was spent
      next unless spent.positive? && stored > spent * Order::MAX_SAVINGS_MULTIPLE

      recomputed = order.calculate_savings
      say "Order ##{order.id}: savings $#{stored.round(2)} -> $#{recomputed} (spent $#{spent.round(2)})"
      order.update_columns(savings_amount: recomputed)
      repaired += 1
    end

    say "Repaired savings on #{repaired} orders"
  end
end
