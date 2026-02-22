class AddSourceToSupplierListItems < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_list_items, :source, :string, default: 'order_guide', null: false
  end
end
