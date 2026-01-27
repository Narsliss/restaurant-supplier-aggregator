class CreateOrderItems < ActiveRecord::Migration[7.1]
  def change
    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: { on_delete: :cascade }
      t.references :supplier_product, null: false, foreign_key: { on_delete: :restrict }
      t.decimal :quantity, precision: 10, scale: 2, null: false
      t.decimal :unit_price, precision: 10, scale: 2, null: false
      t.decimal :line_total, precision: 10, scale: 2, null: false
      t.string :status, default: "pending"
      t.text :notes

      t.timestamps
    end

    add_index :order_items, :status
  end
end
