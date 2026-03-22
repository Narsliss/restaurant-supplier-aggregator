# Restore 12 PPO products that were falsely marked in_stock=false on 2026-03-22.
# A concurrent browser resource contention issue caused "Element is not focusable"
# errors for all items, which the error handler incorrectly treated as stock issues.
# The root cause code has been fixed to only mark products out-of-stock for genuine
# stock errors (e.g., "out of stock", "discontinued"), not browser rendering failures.
class RestorePpoProductsFalselyMarkedOutOfStock < ActiveRecord::Migration[7.1]
  def up
    # These SKUs were all marked in_stock=false by PlaceOrderJob at 11:40 UTC
    # due to "Element is not focusable" browser errors, not actual stock issues.
    ppo = Supplier.find_by(code: 'premiere_produce_one') || Supplier.find_by(name: 'Premiere Produce One')
    return unless ppo

    skus = %w[83258 94744 21026 20910 60210 83104 40094 40096 20920 40070 21445 83108]

    updated = SupplierProduct.where(supplier: ppo, supplier_sku: skus, in_stock: false)
                             .update_all(in_stock: true)

    say "Restored #{updated} PPO products to in_stock=true"
  end

  def down
    # No-op — we don't want to re-break these products
  end
end
