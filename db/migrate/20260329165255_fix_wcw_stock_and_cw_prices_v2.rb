class FixWcwStockAndCwPricesV2 < ActiveRecord::Migration[7.1]
  def up
    # V2: The original migration used wrong supplier codes ('wcw'/'cw' instead
    # of 'whatchefswant'/'chefswarehouse'), so all fixes were silently skipped.

    wcw = Supplier.find_by(code: 'whatchefswant')
    if wcw
      restored = wcw.supplier_products.where(in_stock: false, discontinued: false).update_all(in_stock: true)
      say "Restored #{restored} WCW products to in_stock"

      restored_items = SupplierListItem.joins(:supplier_list)
                                       .where(supplier_lists: { supplier_id: wcw.id })
                                       .where(in_stock: false)
                                       .update_all(in_stock: true)
      say "Restored #{restored_items} WCW list items to in_stock"

      # Fix WCW orders with $0 total (0.0.presence bug)
      zero_orders = Order.where(supplier: wcw, status: %w[submitted confirmed dry_run_complete])
                         .where('total_amount IS NULL OR total_amount = 0')
      count = 0
      zero_orders.find_each do |order|
        correct_total = order.order_items.sum(:line_total)
        if correct_total > 0
          order.update_columns(total_amount: correct_total, subtotal: correct_total)
          count += 1
        end
      end
      say "Recalculated #{count} WCW orders with $0 total"
    else
      say "WCW supplier not found (code: whatchefswant) — skipping"
    end

    cw = Supplier.find_by(code: 'chefswarehouse')
    if cw
      cleared = cw.supplier_products.where.not(price_unit: [nil, '']).update_all(price_unit: nil)
      say "Cleared price_unit on #{cleared} CW products"

      inflated = cw.supplier_products.where('current_price > ?', 2000)
      inflated_count = inflated.count
      inflated.update_all(current_price: nil, price_updated_at: nil)
      say "Reset #{inflated_count} CW products with inflated prices (> $2000)"

      cleared_items = SupplierListItem.joins(:supplier_list)
                                      .where(supplier_lists: { supplier_id: cw.id })
                                      .where.not(price_unit: [nil, ''])
                                      .update_all(price_unit: nil)
      say "Cleared price_unit on #{cleared_items} CW list items"
    else
      say "CW supplier not found (code: chefswarehouse) — skipping"
    end
  end

  def down
    # Data fix — not reversible
  end
end
