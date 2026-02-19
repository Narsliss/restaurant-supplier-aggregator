class CreateProductMatches < ActiveRecord::Migration[7.1]
  def change
    create_table :product_matches do |t|
      t.references :aggregated_list, null: false, foreign_key: { on_delete: :cascade }
      t.string :canonical_name
      t.string :match_status, default: 'auto_matched', null: false
      t.decimal :confidence_score, precision: 3, scale: 2, default: 0.0
      t.integer :position, default: 0

      t.timestamps
    end

    add_index :product_matches, %i[aggregated_list_id position]
    add_index :product_matches, :match_status
  end
end
