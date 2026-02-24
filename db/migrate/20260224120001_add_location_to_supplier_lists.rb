class AddLocationToSupplierLists < ActiveRecord::Migration[7.1]
  def up
    add_reference :supplier_lists, :location, foreign_key: true, null: true

    # Backfill from the credential's location
    execute <<~SQL
      UPDATE supplier_lists sl
      SET location_id = sc.location_id
      FROM supplier_credentials sc
      WHERE sl.supplier_credential_id = sc.id
        AND sc.location_id IS NOT NULL
    SQL
  end

  def down
    remove_reference :supplier_lists, :location
  end
end
