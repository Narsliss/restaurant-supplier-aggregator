# Runs AI product matching for an AggregatedList in the background.
# Concurrency limited to 1 per list so duplicate clicks don't cause
# overlapping jobs that create duplicate matches.
class AiProductMatchJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(aggregated_list_id) { "ai_match_#{aggregated_list_id}" }

  def perform(aggregated_list_id)
    aggregated_list = AggregatedList.find_by(id: aggregated_list_id)
    return unless aggregated_list

    service = AiProductMatcherService.new(aggregated_list)
    service.call
  end
end
