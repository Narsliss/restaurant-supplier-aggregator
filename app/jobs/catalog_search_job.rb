# Searches the full supplier product catalog for matches to unmatched items
# in an AggregatedList. Creates SupplierListItems from SupplierProducts and
# links them into existing ProductMatch rows.
class CatalogSearchJob < ApplicationJob
  queue_as :default

  def perform(aggregated_list_id, match_ids: nil)
    aggregated_list = AggregatedList.find_by(id: aggregated_list_id)
    return unless aggregated_list

    service = CatalogSearchService.new(aggregated_list, match_ids: match_ids)
    service.call
  ensure
    if aggregated_list
      aggregated_list.mark_catalog_search_done!
      # End of the sign-up chain (match → catalog search). A re-search of
      # specific rows from the matching screen is a chef tidying up, not a list
      # being built, so it stays quiet.
      MatchCompletionNotifier.call(aggregated_list.reload) if match_ids.nil?
    end
  end
end
