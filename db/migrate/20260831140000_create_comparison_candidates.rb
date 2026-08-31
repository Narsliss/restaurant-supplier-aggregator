class CreateComparisonCandidates < ActiveRecord::Migration[7.1]
  # Cross-supplier alternatives found automatically for products a chef actually
  # buys, kept deliberately apart from ProductMatch.
  #
  # ProductMatch is the chef's own curation and is never written to by anything
  # but the chef. This table is the machine's opinion: it exists only so the
  # savings calculation has something to compare against on the ~86% of spend
  # that has no matched peer, and it can be rebuilt or thrown away at any time
  # without touching a single thing anyone curated.
  def change
    create_table :comparison_candidates do |t|
      t.references :supplier_product, null: false, foreign_key: true, index: false
      t.references :candidate_supplier_product, null: false,
                   foreign_key: { to_table: :supplier_products }, index: true
      t.decimal :similarity, precision: 5, scale: 4, null: false
      t.string :source, null: false, default: "auto_basket"
      t.timestamps
    end

    add_index :comparison_candidates,
              %i[supplier_product_id candidate_supplier_product_id],
              unique: true, name: "idx_comparison_candidates_pair"
    add_index :comparison_candidates, %i[supplier_product_id similarity],
              name: "idx_comparison_candidates_lookup"
  end
end
