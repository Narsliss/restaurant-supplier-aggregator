class AddInboundPriceListToSupplierLists < ActiveRecord::Migration[7.1]
  def change
    add_reference :supplier_lists, :inbound_price_list, null: true, foreign_key: true
  end
end
