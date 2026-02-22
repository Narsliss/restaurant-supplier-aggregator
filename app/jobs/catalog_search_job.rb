# Searches the full supplier product catalog for matches to unmatched items
# in an AggregatedList. Creates SupplierListItems from SupplierProducts and
# links them into existing ProductMatch rows.
class CatalogSearchJob < ApplicationJob
  queue_as :default

  def perform(aggregated_list_id)
    aggregated_list = AggregatedList.find_by(id: aggregated_list_id)
    return unless aggregated_list

    service = CatalogSearchService.new(aggregated_list)
    service.call
  ensure
    aggregated_list&.mark_catalog_search_done! if aggregated_list
  end
end
