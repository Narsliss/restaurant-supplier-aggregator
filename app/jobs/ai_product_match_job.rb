# Runs AI product matching for an AggregatedList in the background.
class AiProductMatchJob < ApplicationJob
  queue_as :default

  def perform(aggregated_list_id)
    aggregated_list = AggregatedList.find_by(id: aggregated_list_id)
    return unless aggregated_list

    service = AiProductMatcherService.new(aggregated_list)
    service.call
  end
end
