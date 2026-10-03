# Recurring sweep: an order still "processing" long after placement should
# have finished (worker killed mid-job, supplier hung) looks to the chef like
# it is going through. Email the chef and owner(s) once per stuck spell.
# Alert only — the status is left alone, since a job may still be queued.
class StuckOrderAlertJob < ApplicationJob
  queue_as :default

  STUCK_AFTER = 15.minutes
  LOOKBACK = 1.day

  def perform
    Order.where(status: 'processing', updated_at: LOOKBACK.ago..STUCK_AFTER.ago).find_each do |order|
      token = order.updated_at.to_f
      next if OrderFailureAlertJob.read(OrderFailureAlertJob.sent_key(order.id, token))

      OrderFailureAlertJob.perform_now(order.id, token, 'stuck')
    rescue StandardError => e
      Rails.logger.error "[StuckOrderAlert] Order #{order.id}: #{e.class}: #{e.message}"
    end
  end
end
