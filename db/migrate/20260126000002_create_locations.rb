class CreateLocations < ActiveRecord::Migration[7.1]
  def change
    create_table :locations do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :address
      t.string :city
      t.string :state
      t.string :zip_code
      t.string :phone
      t.boolean :is_default, default: false

      t.timestamps
    end

    add_index :locations, [:user_id, :is_default]
  end
end
