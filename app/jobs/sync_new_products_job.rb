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
      fill_from_product_map(aggregated_list)
      return
    end

    result = IncrementalProductMatcherService.new(aggregated_list, items: new_items).call

    # Self-heal: collapse any identical-product lines (same supplier_product
    # on two lines — overlap between one supplier's lists). Zero-judgment,
    # machine lines only.
    deduped = MatchedListCleanupService.new(aggregated_list).auto_merge_same_product

    Rails.logger.info "[SyncNewProductsJob] List #{aggregated_list_id}: " \
                      "#{result[:new_matched]} matched, #{result[:new_unmatched]} unmatched " \
                      "(of which #{result[:split]} split from supplier-slot conflicts, " \
                      "#{result[:redundant]} redundant same-product skips, #{deduped} auto-deduped), " \
                      "#{result[:errored]} errored, #{result[:total_new]} total new items"
    if result[:errored].to_i > 0
      Rails.logger.warn "[SyncNewProductsJob] List #{aggregated_list_id}: " \
                        "#{result[:errored]} item(s) errored — first 5: #{result[:errors].first(5).inspect}"
    end

    # Then the other direction: every row gets each connected supplier's
    # product from the shared product map (the blueprint), not just the ones
    # on that supplier's order guide. Before catalog search, so the map wins.
    fill_from_product_map(aggregated_list)

    # Chain catalog search for unmatched items (same as other match jobs)
    if aggregated_list.reload.matched? && aggregated_list.unmatched_count > 0
      aggregated_list.update(catalog_search_status: 'searching')
      CatalogSearchJob.perform_later(aggregated_list.id)
    end
  end

  private

  # Additive and guarded (see ProductMapFillService); a failure here never
  # undoes or blocks the guide matching above.
  def fill_from_product_map(aggregated_list)
    ProductMapFillService.new(aggregated_list).call
  rescue StandardError => e
    Rails.logger.error "[SyncNewProductsJob] Product map fill failed for list #{aggregated_list.id}: #{e.class} #{e.message}"
  end
end
