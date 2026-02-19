class CreateAggregatedLists < ActiveRecord::Migration[7.1]
  def change
    create_table :aggregated_lists do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.text :description
      t.string :match_status, default: 'pending', null: false

      t.timestamps
    end

    add_index :aggregated_lists, %i[organization_id name], unique: true
  end
end
