# frozen_string_literal: true

# After a US Foods order is submitted, USF finalizes exceptions (out of stock,
# substitutions, short-fills) a short time later — not in the submit response.
# This job re-fetches the order and records any exceptions so the chef gets
# alerted fast, while they're likely still in the app.
#
# It re-polls a few times over the first ~minute because the exceptions may not
# be populated the instant we ask.
class CheckOrderExceptionsJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 3
  RETRY_WAIT = 25.seconds

  def perform(order_id, attempt = 1)
    order = Order.find_by(id: order_id)
    return unless order
    return unless order.status.in?(%w[submitted confirmed])

    exceptions = Orders::SupplierExceptionChecker.new(order).check!

    # No exceptions found yet on a fresh order — USF may still be finalizing.
    # Re-poll so the alert appears within ~a minute. Once we find any, stop.
    if exceptions.blank? && attempt < MAX_ATTEMPTS && order.submitted_at.present? && order.submitted_at > 10.minutes.ago
      self.class.set(wait: RETRY_WAIT).perform_later(order_id, attempt + 1)
    end
  end
end
