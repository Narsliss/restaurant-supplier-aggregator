class CreateOrderListItems < ActiveRecord::Migration[7.1]
  def change
    create_table :order_list_items do |t|
      t.references :order_list, null: false, foreign_key: { on_delete: :cascade }
      t.references :product, null: false, foreign_key: { on_delete: :cascade }
      t.decimal :quantity, precision: 10, scale: 2, null: false, default: 1
      t.text :notes
      t.integer :position, default: 0

      t.timestamps
    end

    add_index :order_list_items, [:order_list_id, :product_id], unique: true
    add_index :order_list_items, [:order_list_id, :position]
  end
end
