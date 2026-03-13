class AddSupplierNameToOrdersAndMakeSupplierOptional < ActiveRecord::Migration[7.1]
  def up
    add_column :orders, :supplier_name, :string

    # Backfill supplier_name from the associated supplier
    execute <<~SQL
      UPDATE orders
      SET supplier_name = suppliers.name
      FROM suppliers
      WHERE orders.supplier_id = suppliers.id
        AND orders.supplier_name IS NULL
    SQL

    change_column_null :orders, :supplier_id, true
  end

  def down
    # Re-associate orphaned orders would require manual intervention
    change_column_null :orders, :supplier_id, false
    remove_column :orders, :supplier_name
  end
end
