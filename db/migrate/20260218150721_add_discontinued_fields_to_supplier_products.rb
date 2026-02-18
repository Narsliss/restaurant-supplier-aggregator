class AddDiscontinuedFieldsToSupplierProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_products, :discontinued, :boolean, default: false, null: false
    add_column :supplier_products, :consecutive_misses, :integer, default: 0, null: false
    add_column :supplier_products, :discontinued_at, :datetime

    add_index :supplier_products, :discontinued
    add_index :supplier_products, :consecutive_misses
  end
end
