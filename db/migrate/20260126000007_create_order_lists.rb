class CreateOrderLists < ActiveRecord::Migration[7.1]
  def change
    create_table :order_lists do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :description
      t.boolean :is_favorite, default: false
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :order_lists, [:user_id, :is_favorite]
    add_index :order_lists, [:user_id, :last_used_at]
  end
end
