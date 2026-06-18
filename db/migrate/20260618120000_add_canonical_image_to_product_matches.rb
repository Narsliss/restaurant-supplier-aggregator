# frozen_string_literal: true

class AddCanonicalImageToProductMatches < ActiveRecord::Migration[7.1]
  def change
    # The supplier_product whose mirrored thumbnail represents this match
    # (chef-chosen in the matching modal; defaults to the primary item's).
    add_column :product_matches, :canonical_image_supplier_product_id, :bigint
    add_index :product_matches, :canonical_image_supplier_product_id,
              name: "idx_product_matches_on_canonical_image_sp"
  end
end
