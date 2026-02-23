class CreateMembershipLocations < ActiveRecord::Migration[7.1]
  def change
    create_table :membership_locations do |t|
      t.references :membership, null: false, foreign_key: { on_delete: :cascade }
      t.references :location, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end

    add_index :membership_locations, [:membership_id, :location_id], unique: true
  end
end
