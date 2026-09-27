class AddSupplierRestaurantsToSupplierCredentials < ActiveRecord::Migration[7.1]
  # The restaurants an owner's supplier login can order for, as last read from
  # the supplier: [{ "id", "name", "street", "city", "zip", "meta" }]. Lets the
  # automatic linker (Suppliers::RestaurantAutoLinker) and the suppliers page
  # show which restaurants are linked, unplaced, or not on the login — without
  # a live supplier call per page load. See docs/owner-multi-location-findings.md.
  def change
    add_column :supplier_credentials, :supplier_restaurants, :jsonb, null: false, default: []
    add_column :supplier_credentials, :supplier_restaurants_checked_at, :datetime
  end
end
