class CreateSupplierDeliverySchedules < ActiveRecord::Migration[7.1]
  def change
    create_table :supplier_delivery_schedules do |t|
      t.references :supplier, null: false, foreign_key: { on_delete: :cascade }
      t.references :location, foreign_key: { on_delete: :cascade }
      t.integer :day_of_week, null: false  # 0=Sunday, 6=Saturday
      t.integer :cutoff_day, null: false   # Day order must be placed
      t.time :cutoff_time, null: false     # Time order must be placed
      t.string :delivery_window            # e.g., "6AM-12PM"
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :supplier_delivery_schedules, [:supplier_id, :day_of_week]
    add_index :supplier_delivery_schedules, [:supplier_id, :location_id]
  end
end
