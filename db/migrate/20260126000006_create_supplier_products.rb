class CreateSupplierProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :supplier_products do |t|
      t.references :product, foreign_key: { on_delete: :nullify }
      t.references :supplier, null: false, foreign_key: { on_delete: :cascade }

      t.string :supplier_sku, null: false
      t.string :supplier_name, null: false
      t.string :supplier_url
      t.decimal :current_price, precision: 10, scale: 2
      t.decimal :previous_price, precision: 10, scale: 2
      t.string :pack_size
      t.integer :minimum_quantity, default: 1
      t.integer :maximum_quantity
      t.boolean :in_stock, default: true
      t.datetime :price_updated_at
      t.datetime :last_scraped_at

      t.timestamps
    end

    add_index :supplier_products, [:supplier_id, :supplier_sku], unique: true
    add_index :supplier_products, :supplier_name
    add_index :supplier_products, :in_stock
  end
end
