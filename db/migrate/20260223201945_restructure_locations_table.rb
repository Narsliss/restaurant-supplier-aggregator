class RestructureLocationsTable < ActiveRecord::Migration[7.1]
  def change
    # organization_id is now required (backfilled in previous migration)
    change_column_null :locations, :organization_id, false

    # user_id becomes optional (locations are org-owned now)
    change_column_null :locations, :user_id, true

    # Track who created the location
    add_reference :locations, :created_by, foreign_key: { to_table: :users, on_delete: :nullify }, null: true

    # Copy existing user_id to created_by for audit trail
    reversible do |dir|
      dir.up do
        execute "UPDATE locations SET created_by_id = user_id WHERE created_by_id IS NULL"
      end
    end

    # Replace user-scoped uniqueness with org-scoped
    remove_index :locations, [:user_id, :is_default], if_exists: true
    add_index :locations, [:organization_id, :name], unique: true, name: "index_locations_on_org_and_name"
  end
end
