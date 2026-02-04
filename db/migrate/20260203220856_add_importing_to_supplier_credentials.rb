class AddImportingToSupplierCredentials < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_credentials, :importing, :boolean, default: false, null: false
    add_column :supplier_credentials, :last_import_at, :datetime
  end
end
