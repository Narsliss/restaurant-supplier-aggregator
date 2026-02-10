class AddPasswordRequiredToSuppliers < ActiveRecord::Migration[7.1]
  def change
    add_column :suppliers, :password_required, :boolean, default: true, null: false
  end
end
