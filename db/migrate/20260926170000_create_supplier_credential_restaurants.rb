class CreateSupplierCredentialRestaurants < ActiveRecord::Migration[7.1]
  # An owner's single supplier login can order for several of their restaurants
  # (US Foods customers, Chef's Warehouse organizations, What Chefs Want
  # companies). A restaurant match ties one such supplier-side restaurant to one
  # EnPlace location, so syncs and orders switch the login to the right
  # restaurant first. Only owners/managers can create them; a connection with no
  # matches behaves exactly as before. See docs/owner-multi-location-findings.md.
  def change
    create_table :supplier_credential_restaurants do |t|
      t.references :supplier_credential, null: false, foreign_key: { on_delete: :cascade }
      t.references :location, null: false, foreign_key: { on_delete: :cascade }
      t.string :supplier_account_id, null: false
      t.string :account_name
      t.jsonb :account_meta, null: false, default: {}
      t.timestamps
    end
    add_index :supplier_credential_restaurants, [:supplier_credential_id, :location_id],
              unique: true, name: "idx_cred_restaurants_cred_location"
    add_index :supplier_credential_restaurants, [:supplier_credential_id, :supplier_account_id],
              unique: true, name: "idx_cred_restaurants_cred_account"

    # How many restaurants the login reported at its last validation — lets the
    # suppliers page offer "match your restaurants" without a live call per load.
    add_column :supplier_credentials, :supplier_restaurant_count, :integer
  end
end
