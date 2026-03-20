class AddDisplayPositionToSupplierCredentials < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_credentials, :display_position, :integer, default: 0
  end
end
