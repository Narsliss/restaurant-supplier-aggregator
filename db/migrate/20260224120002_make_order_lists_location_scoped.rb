class MakeOrderListsLocationScoped < ActiveRecord::Migration[7.1]
  def up
    # Backfill location_id from user's first assigned location where nil
    execute <<~SQL
      UPDATE order_lists ol
      SET location_id = COALESCE(
        (
          SELECT ml.location_id
          FROM membership_locations ml
          JOIN memberships m ON m.id = ml.membership_id
          WHERE m.user_id = ol.user_id
            AND m.organization_id = ol.organization_id
            AND m.active = true
          ORDER BY ml.id ASC
          LIMIT 1
        ),
        (
          SELECT l.id
          FROM locations l
          WHERE l.organization_id = ol.organization_id
          ORDER BY l.created_at ASC
          LIMIT 1
        )
      )
      WHERE ol.location_id IS NULL
        AND ol.organization_id IS NOT NULL
    SQL

    # Change uniqueness from per-user to per-location
    remove_index :order_lists, [:user_id, :name] if index_exists?(:order_lists, [:user_id, :name])
    add_index :order_lists, [:location_id, :name], unique: true, name: :idx_order_lists_location_name,
              where: "location_id IS NOT NULL"
  end

  def down
    remove_index :order_lists, name: :idx_order_lists_location_name if index_exists?(:order_lists, name: :idx_order_lists_location_name)
    add_index :order_lists, [:user_id, :name], unique: true unless index_exists?(:order_lists, [:user_id, :name])
  end
end
