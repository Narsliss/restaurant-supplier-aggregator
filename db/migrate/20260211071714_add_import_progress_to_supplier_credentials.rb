class AddImportProgressToSupplierCredentials < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_credentials, :import_progress, :integer, default: 0
    add_column :supplier_credentials, :import_total, :integer, default: 0
    add_column :supplier_credentials, :import_status_text, :string
  end
end
