class BackfillOrgAndLocationOnOrdersAndLists < ActiveRecord::Migration[7.1]
  def up
    # Backfill orders.organization_id from user's current_organization
    execute <<~SQL
      UPDATE orders
      SET organization_id = users.current_organization_id
      FROM users
      WHERE orders.user_id = users.id
        AND orders.organization_id IS NULL
        AND users.current_organization_id IS NOT NULL
    SQL

    # Backfill orders.location_id from user's default location
    execute <<~SQL
      UPDATE orders
      SET location_id = locations.id
      FROM locations
      WHERE orders.user_id = locations.user_id
        AND orders.location_id IS NULL
        AND locations.is_default = true
    SQL

    # Backfill order_lists.organization_id
    execute <<~SQL
      UPDATE order_lists
      SET organization_id = users.current_organization_id
      FROM users
      WHERE order_lists.user_id = users.id
        AND order_lists.organization_id IS NULL
        AND users.current_organization_id IS NOT NULL
    SQL

    # Backfill subscriptions.organization_id
    execute <<~SQL
      UPDATE subscriptions
      SET organization_id = users.current_organization_id
      FROM users
      WHERE subscriptions.user_id = users.id
        AND subscriptions.organization_id IS NULL
        AND users.current_organization_id IS NOT NULL
    SQL

    # Add composite indexes for efficient org+location queries
    add_index :orders, [:organization_id, :location_id], name: "index_orders_on_org_and_location", if_not_exists: true
    add_index :order_lists, [:organization_id], name: "index_order_lists_on_org", if_not_exists: true
  end

  def down
    remove_index :orders, name: "index_orders_on_org_and_location", if_exists: true
    remove_index :order_lists, name: "index_order_lists_on_org", if_exists: true
  end
end
