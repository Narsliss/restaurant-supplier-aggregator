class AddBatchIdToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :batch_id, :string
    add_index :orders, :batch_id
  end
end
