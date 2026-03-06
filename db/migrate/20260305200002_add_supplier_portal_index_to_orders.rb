class AddSupplierPortalIndexToOrders < ActiveRecord::Migration[7.1]
  def change
    add_index :orders, [:supplier_id, :status, :submitted_at],
              name: "idx_orders_supplier_status_submitted"
  end
end
