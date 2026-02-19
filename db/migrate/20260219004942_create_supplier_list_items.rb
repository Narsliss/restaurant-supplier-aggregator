class CreateSupplierListItems < ActiveRecord::Migration[7.1]
  def change
    create_table :supplier_list_items do |t|
      t.references :supplier_list, null: false, foreign_key: { on_delete: :cascade }
      t.references :supplier_product, null: true, foreign_key: { on_delete: :nullify }
      t.string :remote_item_id
      t.string :name, null: false
      t.string :sku
      t.decimal :price, precision: 10, scale: 2
      t.string :pack_size
      t.decimal :quantity, precision: 10, scale: 2, default: 1.0
      t.boolean :in_stock, default: true
      t.integer :position, default: 0

      t.timestamps
    end

    add_index :supplier_list_items, %i[supplier_list_id sku], unique: true, name: 'idx_list_items_list_sku'
  end
end
