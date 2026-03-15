class AddProductMatchIdToOrderListItems < ActiveRecord::Migration[7.1]
  def change
    unless column_exists?(:order_list_items, :product_match_id)
      add_reference :order_list_items, :product_match, null: true, foreign_key: { on_delete: :nullify }
    end
    change_column_null :order_list_items, :product_id, true
  end
end
