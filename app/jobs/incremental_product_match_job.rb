# Runs incremental matching when a new supplier guide is added to an existing
# matched list. Uses the same concurrency key as AiProductMatchJob to prevent
# concurrent matching on the same list.
class IncrementalProductMatchJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(aggregated_list_id, _new_supplier_list_ids) {
    "ai_match_#{aggregated_list_id}"
  }

  def perform(aggregated_list_id, new_supplier_list_ids)
    aggregated_list = AggregatedList.find_by(id: aggregated_list_id)
    return unless aggregated_list

    result = IncrementalProductMatcherService.new(aggregated_list, new_supplier_list_ids).call

    Rails.logger.info "[IncrementalProductMatchJob] List #{aggregated_list_id}: " \
                      "#{result[:new_matched]} matched, #{result[:new_unmatched]} unmatched, " \
                      "#{result[:total_new]} total new items"

    # Chain catalog search for unmatched items (same behavior as AiProductMatchJob)
    if aggregated_list.reload.matched? && aggregated_list.unmatched_count > 0
      aggregated_list.update(catalog_search_status: 'searching')
      CatalogSearchJob.perform_later(aggregated_list.id)
    end
  end
end
