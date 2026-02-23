class AddLocationIdToOrderLists < ActiveRecord::Migration[7.1]
  def change
    add_reference :order_lists, :location, foreign_key: { on_delete: :nullify }, null: true
  end
end
