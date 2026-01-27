class CreateSuppliers < ActiveRecord::Migration[7.1]
  def change
    create_table :suppliers do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.string :base_url, null: false
      t.string :login_url, null: false
      t.string :scraper_class, null: false
      t.boolean :active, default: true
      t.text :notes

      t.timestamps
    end

    add_index :suppliers, :code, unique: true
    add_index :suppliers, :active
  end
end
