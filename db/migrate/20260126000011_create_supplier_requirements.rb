class CreateSupplierRequirements < ActiveRecord::Migration[7.1]
  def change
    create_table :supplier_requirements do |t|
      t.references :supplier, null: false, foreign_key: { on_delete: :cascade }
      t.string :requirement_type, null: false
      t.string :value
      t.decimal :numeric_value, precision: 10, scale: 2
      t.text :description
      t.text :error_message, null: false
      t.boolean :is_blocking, default: true
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :supplier_requirements, [:supplier_id, :requirement_type]
    add_index :supplier_requirements, :active
  end
end
