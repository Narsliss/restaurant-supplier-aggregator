class CreateAggregatedListMappings < ActiveRecord::Migration[7.1]
  def change
    create_table :aggregated_list_mappings do |t|
      t.references :aggregated_list, null: false, foreign_key: { on_delete: :cascade }
      t.references :supplier_list, null: false, foreign_key: { on_delete: :cascade }

      t.timestamps
    end

    add_index :aggregated_list_mappings, %i[aggregated_list_id supplier_list_id], unique: true,
                                                                                  name: 'idx_agg_list_mappings_unique'
  end
end
