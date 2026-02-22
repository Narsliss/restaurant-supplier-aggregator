class AddCatalogSearchStatusToAggregatedLists < ActiveRecord::Migration[7.1]
  def change
    add_column :aggregated_lists, :catalog_search_status, :string
  end
end
