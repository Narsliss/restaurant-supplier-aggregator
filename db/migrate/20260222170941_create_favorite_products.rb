class CreateFavoriteProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :favorite_products do |t|
      t.references :user, null: false, foreign_key: true
      t.references :supplier_product, null: false, foreign_key: true

      t.timestamps
    end

    add_index :favorite_products, [:user_id, :supplier_product_id], unique: true
  end
end
