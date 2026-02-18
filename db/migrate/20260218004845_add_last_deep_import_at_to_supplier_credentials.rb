class AddLastDeepImportAtToSupplierCredentials < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_credentials, :last_deep_import_at, :datetime
  end
end
