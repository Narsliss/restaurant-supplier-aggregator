class CreateTeaserMatches < ActiveRecord::Migration[7.1]
  def change
    create_table :teaser_matches do |t|
      t.references :aggregated_list, null: false, foreign_key: true
      t.references :product_match, null: false, foreign_key: true
      t.references :supplier, null: false, foreign_key: true
      t.references :supplier_product, null: false, foreign_key: true
      t.decimal :confidence_score, precision: 3, scale: 2, default: 0.0

      t.timestamps
    end

    add_index :teaser_matches, %i[product_match_id supplier_id], unique: true,
              name: 'index_teaser_matches_on_match_and_supplier'
    add_index :teaser_matches, %i[aggregated_list_id supplier_id],
              name: 'index_teaser_matches_on_list_and_supplier'
  end
end
