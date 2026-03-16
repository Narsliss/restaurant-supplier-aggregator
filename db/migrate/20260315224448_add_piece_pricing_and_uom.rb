class AddPiecePricingAndUom < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_products, :piece_price, :decimal, precision: 10, scale: 2
    add_column :supplier_products, :piece_pack_size, :string

    add_column :supplier_list_items, :piece_price, :decimal, precision: 10, scale: 2
    add_column :supplier_list_items, :piece_pack_size, :string

    add_column :order_items, :uom, :string
  end
end
