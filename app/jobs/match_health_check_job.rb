# Daily: are chefs' matched lists still whole? Counts visible rows with nothing
# in them and the order-list entries pointing at such rows, and emails the
# super admin when either set has grown since the last check — so a problem
# like Sep 15 2026 (a guide refresh silently emptying confirmed rows) is caught
# the next morning, not weeks later by a chef. Read-only apart from its own
# snapshot row.
class MatchHealthCheckJob < ApplicationJob
  queue_as :low

  def perform
    empty_ids = ProductMatch.where.not(match_status: 'rejected')
                            .where.not(id: ProductMatchItem.select(:product_match_id))
                            .pluck(:id).sort
    stranded_ids = OrderListItem.where(product_match_id: empty_ids).pluck(:id).sort

    previous = MatchHealthCheck.order(:created_at, :id).last
    MatchHealthCheck.create!(empty_row_ids: empty_ids, stranded_order_list_item_ids: stranded_ids)

    new_empty = empty_ids - Array(previous&.empty_row_ids)
    new_stranded = stranded_ids - Array(previous&.stranded_order_list_item_ids)
    return if new_empty.empty? && new_stranded.empty?

    MatchHealthMailer.degraded(new_empty_row_ids: new_empty, new_stranded_ids: new_stranded,
                               total_empty: empty_ids.size, total_stranded: stranded_ids.size,
                               first_check: previous.nil?).deliver_later
  end
end
