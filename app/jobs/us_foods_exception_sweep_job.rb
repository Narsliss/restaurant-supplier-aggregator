# frozen_string_literal: true

# Re-checks US Foods orders for out-of-stocks, short-fills and substitutions
# after US Foods allocates stock, and emails the chef + owner(s) when the
# order changed (CheckOrderExceptionsJob with notify: true).
#
#   evening — 7 PM Eastern, orders delivering tomorrow: still time to get the
#             item elsewhere
#   morning — 5 AM Eastern, orders delivering today: last catch
#
# Times are Carmin's starting point (Oct 3 2026) — adjust as we learn when
# US Foods actually allocates. Read-only against US Foods.
class UsFoodsExceptionSweepJob < ApplicationJob
  queue_as :default

  WINDOWS = { 'evening' => 1, 'morning' => 0 }.freeze # days after today (Eastern)
  STAGGER = 20.seconds

  def perform(window = 'evening')
    days_ahead = WINDOWS.fetch(window.to_s)
    delivery_day = Time.find_zone('America/New_York').today + days_ahead

    supplier = Supplier.find_by(code: 'usfoods')
    return unless supplier

    orders = Order.where(supplier_id: supplier.id, status: %w[submitted confirmed], delivery_date: delivery_day)
                  .where.not(confirmation_number: [nil, ''])
                  .where.not('confirmation_number LIKE ?', 'DRY-RUN%')
                  .order(:id)

    orders.each_with_index do |order, i|
      CheckOrderExceptionsJob.set(wait: i * STAGGER)
                             .perform_later(order.id, CheckOrderExceptionsJob::MAX_ATTEMPTS, true)
    end
    Rails.logger.info "[UsFoodsExceptionSweep] #{window}: #{orders.size} US Foods order(s) delivering #{delivery_day}"
  end
end
