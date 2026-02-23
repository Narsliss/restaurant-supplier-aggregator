class AddPriceTrackingToSupplierListItems < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_list_items, :previous_price, :decimal, precision: 10, scale: 2
    add_column :supplier_list_items, :price_updated_at, :datetime
  end
end
