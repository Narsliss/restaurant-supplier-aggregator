# Computes "teaser" cells (suggestions from suppliers the chef has no
# credentials with) for an AggregatedList. Runs on the :low queue so it
# never competes with PlaceOrderJob or interactive matching jobs.
#
# Concurrency limited per AggregatedList so backfill bursts and post-match
# enqueues for the same list collapse into a single in-flight job.
class TeaserCatalogSearchJob < ApplicationJob
  queue_as :low

  limits_concurrency to: 1, key: ->(aggregated_list_id) { "teaser_search_#{aggregated_list_id}" }

  def perform(aggregated_list_id)
    aggregated_list = AggregatedList.find_by(id: aggregated_list_id)
    return unless aggregated_list

    TeaserCatalogSearchService.new(aggregated_list).call
  end
end
