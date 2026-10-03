# frozen_string_literal: true

# After a US Foods order is submitted, USF finalizes exceptions (out of stock,
# substitutions, short-fills) a short time later — not in the submit response.
# This job re-fetches the order and records any exceptions so the chef gets
# alerted fast, while they're likely still in the app.
#
# It re-polls a few times over the first ~minute because the exceptions may not
# be populated the instant we ask.
#
# Allocation happens much later than that (order #332: the vinegar and chevre
# went to 0 reserved after our one-minute check), so UsFoodsExceptionSweepJob
# also runs this the evening before and the morning of delivery with
# notify: true — those runs email the chef + owner(s) when US Foods has
# changed the order (Carmin, Oct 3 2026). The first-minute check stays
# in-app only; anything it found is emailed by the evening sweep.
class CheckOrderExceptionsJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 3
  RETRY_WAIT = 25.seconds
  EMAILED_TTL = 10.days

  def perform(order_id, attempt = 1, notify = false)
    order = Order.find_by(id: order_id)
    return unless order
    return unless order.status.in?(%w[submitted confirmed])

    exceptions = Orders::SupplierExceptionChecker.new(order).check!

    # No exceptions found yet on a fresh order — USF may still be finalizing.
    # Re-poll so the alert appears within ~a minute. Once we find any, stop.
    if exceptions.blank? && attempt < MAX_ATTEMPTS && order.submitted_at.present? && order.submitted_at > 10.minutes.ago
      self.class.set(wait: RETRY_WAIT).perform_later(order_id, attempt + 1)
    end

    email_if_changed(order, exceptions) if notify && exceptions.present?
  end

  private

  # Email once per distinct set of exceptions. If the email fails, nothing is
  # recorded, so the next sweep tries again.
  def email_if_changed(order, exceptions)
    signature = exceptions.map { |e| [e[:sku], e[:type], e[:filled]].join(':') }.sort.join('|')
    key = "usf_exceptions_emailed:#{order.id}"
    return if cache_read(key) == signature

    OrderMailer.supplier_changed_order(order.reload).deliver_now
    cache_write(key, signature)
    Rails.logger.warn "[CheckOrderExceptions] Order #{order.id}: emailed chef + owner(s) about #{exceptions.size} US Foods change(s)"
  rescue StandardError => e
    Rails.logger.error "[CheckOrderExceptions] Order #{order.id}: could not email exceptions: #{e.class}: #{e.message}"
  end

  def cache_read(key)
    Rails.cache.read(key)
  rescue StandardError
    nil
  end

  def cache_write(key, value)
    Rails.cache.write(key, value, expires_in: EMAILED_TTL)
  rescue StandardError
    nil
  end
end
