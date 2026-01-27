class CreateProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :products do |t|
      t.string :name, null: false
      t.string :normalized_name
      t.string :category
      t.string :subcategory
      t.string :unit_size
      t.string :unit_type
      t.string :upc
      t.string :brand
      t.text :description

      t.timestamps
    end

    add_index :products, :name
    add_index :products, :normalized_name
    add_index :products, :upc
    add_index :products, :category
    add_index :products, [:category, :subcategory]
  end
end
