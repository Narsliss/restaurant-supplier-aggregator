class AllowNullPasswordOnSupplierCredentials < ActiveRecord::Migration[7.1]
  def change
    change_column_null :supplier_credentials, :encrypted_password, true
    change_column_null :supplier_credentials, :encrypted_password_iv, true
  end
end
