class AddCompositeIndexesForScopedQueries < ActiveRecord::Migration[7.1]
  def change
    # Composite indexes for scoped queries that filter by (organization_id, location_id)
    add_index :supplier_credentials, [:organization_id, :location_id],
              name: "idx_supplier_creds_org_location"

    add_index :supplier_lists, [:organization_id, :location_id],
              name: "idx_supplier_lists_org_location"

    # Replace duplicate order_lists organization_id index with composite
    remove_index :order_lists, name: "index_order_lists_on_org"
    add_index :order_lists, [:organization_id, :location_id],
              name: "idx_order_lists_org_location"

    # Composite index for orders filtered by organization + created_at (reports, dashboard)
    add_index :orders, [:organization_id, :created_at],
              name: "idx_orders_org_created_at"
  end
end
