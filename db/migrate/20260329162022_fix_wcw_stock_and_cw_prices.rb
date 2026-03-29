class FixWcwStockAndCwPrices < ActiveRecord::Migration[7.1]
  def up
    # Issue 1: WCW products falsely marked out of stock.
    # isOutOfStock was delivery-date-specific, not permanent.
    # Restore all non-discontinued WCW products to in_stock.
    wcw = Supplier.find_by(code: 'wcw')
    if wcw
      restored = wcw.supplier_products.where(in_stock: false, discontinued: false).update_all(in_stock: true)
      say "Restored #{restored} WCW products to in_stock"
    end

    # Also fix WCW list items
    if wcw
      restored_items = SupplierListItem.joins(:supplier_list)
                                       .where(supplier_lists: { supplier_id: wcw.id })
                                       .where(in_stock: false)
                                       .update_all(in_stock: true)
      say "Restored #{restored_items} WCW list items to in_stock"
    end

    # Issue 2: CW products with inflated prices from double-multiplication bug.
    # price_unit was incorrectly set from CW's selling UOM (e.g., "OZ"),
    # causing estimated_total_price to multiply the already-total price by pack weight.
    # Reset price_unit and inflated prices so the next sync corrects them.
    cw = Supplier.find_by(code: 'cw')
    if cw
      # Clear price_unit on all CW products — CW always returns total selling price
      cleared = cw.supplier_products.where.not(price_unit: [nil, '']).update_all(price_unit: nil)
      say "Cleared price_unit on #{cleared} CW products"

      # Reset obviously inflated prices (> $2000 for a single item is unrealistic)
      inflated = cw.supplier_products.where('current_price > ?', 2000)
      inflated_count = inflated.count
      inflated.update_all(current_price: nil, price_updated_at: nil)
      say "Reset #{inflated_count} CW products with inflated prices (> $2000)"

      # Also clear price_unit on CW list items
      cleared_items = SupplierListItem.joins(:supplier_list)
                                      .where(supplier_lists: { supplier_id: cw.id })
                                      .where.not(price_unit: [nil, ''])
                                      .update_all(price_unit: nil)
      say "Cleared price_unit on #{cleared_items} CW list items"
    end

    # Issue 3: WCW submitted orders with $0 total due to 0.0.presence bug.
    # Recalculate total_amount from line items for any submitted WCW orders showing $0.
    if wcw
      zero_orders = Order.where(supplier: wcw, status: %w[submitted confirmed dry_run_complete])
                         .where('total_amount IS NULL OR total_amount = 0')
      zero_orders.find_each do |order|
        correct_total = order.order_items.sum(:line_total)
        if correct_total > 0
          order.update_columns(total_amount: correct_total, subtotal: correct_total)
        end
      end
      say "Recalculated #{zero_orders.count} WCW orders with $0 total"
    end
  end

  def down
    # Data fix — not reversible
  end
end
