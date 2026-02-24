class AddLocationToSupplierCredentials < ActiveRecord::Migration[7.1]
  def up
    # Add location_id to supplier_credentials
    add_reference :supplier_credentials, :location, foreign_key: true, null: true

    # Backfill: assign each credential to the user's first assigned location,
    # or the org's first location as fallback
    execute <<~SQL
      UPDATE supplier_credentials sc
      SET location_id = COALESCE(
        (
          SELECT ml.location_id
          FROM membership_locations ml
          JOIN memberships m ON m.id = ml.membership_id
          WHERE m.user_id = sc.user_id
            AND m.organization_id = sc.organization_id
            AND m.active = true
          ORDER BY ml.id ASC
          LIMIT 1
        ),
        (
          SELECT l.id
          FROM locations l
          WHERE l.organization_id = sc.organization_id
          ORDER BY l.created_at ASC
          LIMIT 1
        )
      )
      WHERE sc.organization_id IS NOT NULL
    SQL

    # Update unique index: allow same user to have same supplier at different locations
    remove_index :supplier_credentials, name: :idx_supplier_creds_unique
    add_index :supplier_credentials, [:user_id, :supplier_id, :location_id],
              unique: true, name: :idx_supplier_creds_unique
  end

  def down
    remove_index :supplier_credentials, name: :idx_supplier_creds_unique
    add_index :supplier_credentials, [:user_id, :supplier_id],
              unique: true, name: :idx_supplier_creds_unique
    remove_reference :supplier_credentials, :location
  end
end
