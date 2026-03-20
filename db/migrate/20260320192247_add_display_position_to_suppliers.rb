class AddDisplayPositionToSuppliers < ActiveRecord::Migration[7.1]
  def change
    add_column :suppliers, :display_position, :integer, default: 0
  end
end
