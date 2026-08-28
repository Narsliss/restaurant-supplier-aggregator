class CreateUnitOverrides < ActiveRecord::Migration[7.1]
  def change
    create_table :unit_overrides do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :supplier, null: false, foreign_key: true
      # Keyed on the supplier's own SKU, NOT on supplier_list_item_id: US Foods
      # rotates order-guide ids roughly monthly, which spawns a fresh
      # SupplierList and fresh item rows, and an override hung off those would
      # evaporate at every rotation.
      t.string :supplier_sku, null: false

      # NULL means the whole organization; a value narrows it to one location.
      # A group sets a bushel once and splits it only where a city genuinely
      # gets a different box — a supplier reusing one SKU for regionally
      # different packs is the case org-only scoping could not express.
      t.references :location, foreign_key: true

      t.string :basis, null: false, default: "per_pack"
      t.decimal :net_weight_oz, precision: 12, scale: 4, null: false

      # The tripwire. The exact pack string this weight was entered against;
      # when the supplier changes the pack, the override goes dormant rather
      # than silently carrying a number that no longer describes the box.
      t.string :pack_size_fingerprint, null: false
      t.decimal :price_at_entry, precision: 10, scale: 2

      t.references :created_by_user, foreign_key: { to_table: :users }
      t.string :note
      t.datetime :confirmed_at

      t.timestamps
    end

    add_index :unit_overrides, %i[organization_id location_id supplier_id supplier_sku],
              unique: true, name: "idx_unit_overrides_on_org_location_supplier_sku"
  end
end
