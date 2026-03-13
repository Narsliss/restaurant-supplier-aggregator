class AllowSupplierDeletionCascade < ActiveRecord::Migration[7.1]
  def up
    # Snapshot product info on order_items so they survive supplier_product deletion
    add_column :order_items, :product_name, :string
    add_column :order_items, :product_sku, :string

    # Backfill from supplier_products
    execute <<~SQL
      UPDATE order_items
      SET product_name = sp.supplier_name,
          product_sku  = sp.supplier_sku
      FROM supplier_products sp
      WHERE order_items.supplier_product_id = sp.id
    SQL

    # Make supplier_product_id nullable on order_items
    change_column_null :order_items, :supplier_product_id, true

    # Make supplier_product_id nullable on favorite_products
    change_column_null :favorite_products, :supplier_product_id, true
  end

  def down
    change_column_null :favorite_products, :supplier_product_id, false
    change_column_null :order_items, :supplier_product_id, false
    remove_column :order_items, :product_name
    remove_column :order_items, :product_sku
  end
end
