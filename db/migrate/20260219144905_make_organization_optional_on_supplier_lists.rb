class MakeOrganizationOptionalOnSupplierLists < ActiveRecord::Migration[7.1]
  def change
    change_column_null :supplier_lists, :organization_id, true
  end
end
