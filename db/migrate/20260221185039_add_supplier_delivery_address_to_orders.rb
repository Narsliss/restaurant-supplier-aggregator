class AddSupplierDeliveryAddressToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :supplier_delivery_address, :text
  end
end
