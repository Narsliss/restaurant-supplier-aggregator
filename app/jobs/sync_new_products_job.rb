# Finds supplier list items from connected suppliers that don't yet have a
# ProductMatchItem in the aggregated list, and runs incremental matching on
# just those items. Preserves all existing confirmed/manual matches.
#
# Uses the same concurrency key as AiProductMatchJob and IncrementalProductMatchJob
# to prevent concurrent matching on the same list.
class SyncNewProductsJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(aggregated_list_id) {
    "ai_match_#{aggregated_list_id}"
  }

  def perform(aggregated_list_id)
    aggregated_list = AggregatedList.find_by(id: aggregated_list_id)
    return unless aggregated_list

    new_items = aggregated_list.unmatched_supplier_items
    if new_items.empty?
      aggregated_list.mark_matched!
      Rails.logger.info "[SyncNewProductsJob] List #{aggregated_list_id}: no new items to sync"
      return
    end

    result = IncrementalProductMatcherService.new(aggregated_list, items: new_items).call

    Rails.logger.info "[SyncNewProductsJob] List #{aggregated_list_id}: " \
                      "#{result[:new_matched]} matched, #{result[:new_unmatched]} unmatched, " \
                      "#{result[:total_new]} total new items"

    # Chain catalog search for unmatched items (same as other match jobs)
    if aggregated_list.reload.matched? && aggregated_list.unmatched_count > 0
      aggregated_list.update(catalog_search_status: 'searching')
      CatalogSearchJob.perform_later(aggregated_list.id)
    end
  end
end
