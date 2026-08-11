class AddDuplicateDismissedAtToProductMatches < ActiveRecord::Migration[7.1]
  def change
    add_column :product_matches, :duplicate_dismissed_at, :datetime
  end
end
