class AddCaseMinimumSupportToSupplierRequirements < ActiveRecord::Migration[7.1]
  def change
    add_reference :supplier_requirements, :location,
                  null: true,
                  foreign_key: { on_delete: :cascade }

    # Replace old index with one that includes location_id
    remove_index :supplier_requirements,
                 name: "idx_on_supplier_id_requirement_type_79869f2f8a"

    add_index :supplier_requirements,
              [:supplier_id, :requirement_type, :location_id],
              name: "idx_supplier_req_type_location",
              unique: true

    # Partial index for global defaults (location_id IS NULL)
    add_index :supplier_requirements,
              [:supplier_id, :requirement_type],
              name: "idx_supplier_req_type_global",
              unique: true,
              where: "location_id IS NULL"
  end
end
