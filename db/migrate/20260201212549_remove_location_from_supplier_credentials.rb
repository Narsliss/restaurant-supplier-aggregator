class RemoveLocationFromSupplierCredentials < ActiveRecord::Migration[7.1]
  def up
    # Remove the old unique index that included location_id
    remove_index :supplier_credentials, name: "idx_supplier_creds_unique"

    # Remove the location foreign key and column
    remove_foreign_key :supplier_credentials, :locations
    remove_column :supplier_credentials, :location_id

    # Add new unique index: one credential per user per supplier
    add_index :supplier_credentials, [:user_id, :supplier_id],
              unique: true, name: "idx_supplier_creds_unique"
  end

  def down
    # Remove the new unique index
    remove_index :supplier_credentials, name: "idx_supplier_creds_unique"

    # Re-add location_id column
    add_reference :supplier_credentials, :location, foreign_key: { on_delete: :cascade }

    # Re-add the old unique index with location_id
    add_index :supplier_credentials, [:user_id, :location_id, :supplier_id],
              unique: true, name: "idx_supplier_creds_unique"
  end
end
