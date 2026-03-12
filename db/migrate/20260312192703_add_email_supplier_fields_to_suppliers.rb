class AddEmailSupplierFieldsToSuppliers < ActiveRecord::Migration[7.1]
  def change
    add_column :suppliers, :contact_email, :string
    add_column :suppliers, :ordering_instructions, :text
    add_column :suppliers, :organization_id, :bigint
    add_column :suppliers, :created_by_id, :bigint

    add_index :suppliers, :contact_email
    add_index :suppliers, :organization_id
    add_foreign_key :suppliers, :organizations, column: :organization_id, on_delete: :cascade
    add_foreign_key :suppliers, :users, column: :created_by_id, on_delete: :nullify
  end
end
