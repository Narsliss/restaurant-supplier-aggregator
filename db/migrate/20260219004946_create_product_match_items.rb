class CreateProductMatchItems < ActiveRecord::Migration[7.1]
  def change
    create_table :product_match_items do |t|
      t.references :product_match, null: false, foreign_key: { on_delete: :cascade }
      t.references :supplier_list_item, null: false, foreign_key: { on_delete: :cascade }
      t.references :supplier, null: false, foreign_key: true
      t.boolean :is_primary, default: false, null: false

      t.timestamps
    end

    add_index :product_match_items, %i[product_match_id supplier_id], unique: true,
                                                                      name: 'idx_match_items_match_supplier'
  end
end
