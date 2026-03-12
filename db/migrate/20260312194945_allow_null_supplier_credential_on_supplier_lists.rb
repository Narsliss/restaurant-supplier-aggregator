class AllowNullSupplierCredentialOnSupplierLists < ActiveRecord::Migration[7.1]
  def change
    change_column_null :supplier_lists, :supplier_credential_id, true
  end
end
