class CreateOrderListSeedRecords < ActiveRecord::Migration[7.1]
  def change
    create_table :order_list_seed_records do |t|
      t.references :location, null: false, foreign_key: true
      t.references :supplier, null: false, foreign_key: true
      t.datetime :seeded_at

      t.timestamps
    end

    add_index :order_list_seed_records, [:location_id, :supplier_id], unique: true
  end
end
