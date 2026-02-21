class AddRefreshFailuresToSupplierCredentials < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_credentials, :refresh_failures, :integer, default: 0, null: false
  end
end
