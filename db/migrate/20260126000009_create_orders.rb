class CreateOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :orders do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :location, foreign_key: { on_delete: :nullify }
      t.references :supplier, null: false, foreign_key: { on_delete: :restrict }
      t.references :order_list, foreign_key: { on_delete: :nullify }

      t.string :status, null: false, default: "pending"
      t.string :confirmation_number
      t.decimal :subtotal, precision: 10, scale: 2
      t.decimal :tax, precision: 10, scale: 2
      t.decimal :total_amount, precision: 10, scale: 2
      t.date :delivery_date
      t.text :notes
      t.text :error_message
      t.datetime :submitted_at
      t.datetime :confirmed_at

      t.timestamps
    end

    add_index :orders, :status
    add_index :orders, :submitted_at
    add_index :orders, :confirmation_number
    add_index :orders, [:user_id, :status]
    add_index :orders, [:user_id, :submitted_at]
  end
end
