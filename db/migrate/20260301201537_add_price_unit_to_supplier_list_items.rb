class AddPriceUnitToSupplierListItems < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_list_items, :price_unit, :string
  end
end
