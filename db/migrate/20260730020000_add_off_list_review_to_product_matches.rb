# Chefs can now order anything a connected supplier carries, mid-shift, without
# curating a list first (commit 31cf631). Those additions land on the matched
# list with a single supplier and no price comparison, so owners/managers need
# to know they happened and review them. These columns track that.
class AddOffListReviewToProductMatches < ActiveRecord::Migration[7.1]
  def change
    add_column :product_matches, :off_list_added_at, :datetime
    add_reference :product_matches, :off_list_added_by, foreign_key: { to_table: :users }, null: true
    add_column :product_matches, :reviewed_at, :datetime

    # Powers the dashboard alert count and the "unreviewed first" ordering
    add_index :product_matches, %i[aggregated_list_id off_list_added_at reviewed_at],
              name: "idx_product_matches_off_list_review"
  end
end
