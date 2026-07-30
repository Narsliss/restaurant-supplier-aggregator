# frozen_string_literal: true

# Emails owners + managers when a chef orders a product that wasn't on any
# matched list. Runs off the request so a busy-shift add is never slowed by
# mail delivery, and a mail failure can never block the chef's order.
class NotifyOffListOrderJob < ApplicationJob
  queue_as :low

  discard_on ActiveJob::DeserializationError

  def perform(product_match_id)
    match = ProductMatch.includes(:aggregated_list, :off_list_added_by,
                                  product_match_items: %i[supplier supplier_list_item])
                        .find_by(id: product_match_id)
    return unless match
    return unless match.off_list_added?

    OffListOrderMailer.off_list_product_added(match).deliver_now
  rescue StandardError => e
    # Never retry into a mail loop — the dashboard alert and the matching page
    # still surface the item, so a lost email degrades gracefully.
    Rails.logger.error "[NotifyOffListOrder] match ##{product_match_id}: #{e.class} - #{e.message}"
  end
end
