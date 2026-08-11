class AddPossibleDuplicateOfToProductMatches < ActiveRecord::Migration[7.1]
  def change
    add_column :product_matches, :possible_duplicate_of_id, :bigint
    add_index :product_matches, :possible_duplicate_of_id
  end
end
