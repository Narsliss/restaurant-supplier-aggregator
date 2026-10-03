# Emails the chef who placed an order — and the org owner(s) — when the order
# was NOT placed and the chef didn't see that in the app.
#
# Carmin's rule (Oct 3 2026, after order #386): a failure the chef sees on
# screen and can fix in the app gets no email. One she didn't see (taps
# Submit All, locks her phone) does — a stopped order she never hears about
# means nothing arrives for her shift. Two kinds always email, seen or not:
#   unconfirmed — the supplier may or may not have the order; she can't
#                 settle that in the app
#   stuck       — still "processing" long after it should have finished
#
# "Seen" = an order screen (order page or batch progress, desktop or mobile)
# rendered or polled the order while it was not placed. A locked phone pauses
# that polling, so it counts as unseen. Markers live in Rails.cache (Postgres
# via Solid Cache in production — no migration). Any doubt — cache down,
# evicted, null store — means unseen and not-yet-emailed, so the email goes
# out: a duplicate is acceptable, a missed one is not.
class OrderFailureAlertJob < ApplicationJob
  queue_as :default

  NOT_PLACED_STATUSES = %w[failed pending_review pending_manual].freeze
  KINDS = %w[not_placed unconfirmed stuck].freeze
  SEEN_WINDOW = 2.minutes
  MARKER_TTL = 3.days

  class << self
    # Called when placement ends without placing the order. Never raises:
    # alerting must not disturb the placement code path.
    def schedule(order, kind: 'not_placed')
      kind = 'not_placed' unless KINDS.include?(kind)
      token = Time.current.to_f
      write(failure_key(order.id), token)
      wait = kind == 'not_placed' ? SEEN_WINDOW : 0
      set(wait: wait).perform_later(order.id, token, kind)
    rescue StandardError => e
      Rails.logger.error "[OrderFailureAlert] Could not schedule alert for order #{order&.id}: #{e.class}: #{e.message}"
    end

    # Called by every order screen that shows placement state.
    def mark_seen(orders)
      Array(orders).each do |order|
        next unless NOT_PLACED_STATUSES.include?(order.status)

        write(seen_key(order.id), Time.current.to_f)
      end
    rescue StandardError => e
      Rails.logger.warn "[OrderFailureAlert] Could not record seen: #{e.class}: #{e.message}"
    end

    def failure_key(order_id) = "order_failure_alert:failed:#{order_id}"
    def seen_key(order_id) = "order_failure_alert:seen:#{order_id}"
    def sent_key(order_id, token) = "order_failure_alert:sent:#{order_id}:#{token}"

    def read(key)
      Rails.cache.read(key)
    rescue StandardError
      nil
    end

    def write(key, value)
      Rails.cache.write(key, value, expires_in: MARKER_TTL)
    rescue StandardError
      nil
    end
  end

  def perform(order_id, token, kind = 'not_placed')
    order = Order.find_by(id: order_id)
    return unless order
    return unless still_not_placed?(order, kind)

    unless kind == 'stuck'
      # A newer attempt failed after this one was scheduled; its own job reports it.
      latest = self.class.read(self.class.failure_key(order.id))
      return if latest && latest.to_f != token.to_f
    end

    if kind == 'not_placed'
      seen = self.class.read(self.class.seen_key(order.id))
      if seen && seen.to_f >= token.to_f
        Rails.logger.info "[OrderFailureAlert] Order #{order.id} failure was seen in the app — no email"
        return
      end
    end

    sent = self.class.sent_key(order.id, token)
    return if self.class.read(sent)

    OrderMailer.order_not_placed(order, kind: kind).deliver_now
    self.class.write(sent, true)
    Rails.logger.warn "[OrderFailureAlert] Order #{order.id} (#{order.status}, #{kind}) — emailed chef and owner(s)"
  end

  private

  def still_not_placed?(order, kind)
    return order.processing? if kind == 'stuck'

    NOT_PLACED_STATUSES.include?(order.status)
  end
end
