class AddPriceUnitToSupplierProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_products, :price_unit, :string
  end
end
