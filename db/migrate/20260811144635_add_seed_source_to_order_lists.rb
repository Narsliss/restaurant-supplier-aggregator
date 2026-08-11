class AddSeedSourceToOrderLists < ActiveRecord::Migration[7.1]
  def change
    add_column :order_lists, :seed_supplier_id, :bigint
    add_column :order_lists, :seeded_at, :datetime
    add_index :order_lists, [:location_id, :seed_supplier_id]
  end
end
