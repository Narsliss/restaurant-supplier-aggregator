class AddCompletionEmailedAtToAggregatedLists < ActiveRecord::Migration[7.1]
  def change
    add_column :aggregated_lists, :completion_emailed_at, :datetime
  end
end
