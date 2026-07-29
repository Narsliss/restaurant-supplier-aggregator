class CreateCurrentOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :current_orders do |t|
      t.references :user, null: false, foreign_key: true
      t.references :aggregated_list, null: false, foreign_key: true
      t.jsonb :state, null: false, default: {}
      t.date :delivery_date

      t.timestamps
    end

    add_index :current_orders, [:user_id, :aggregated_list_id], unique: true
  end
end
