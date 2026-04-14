class ExpireDraftsJob < ApplicationJob
  queue_as :low

  # Deletes draft orders whose draft_saved_at is older than Order::DRAFT_EXPIRY_DAYS.
  # Runs daily via config/recurring.yml. Chefs can reset the timer by returning to
  # checkout on any draft (see OrdersController#review).
  def perform
    cutoff = Order::DRAFT_EXPIRY_DAYS.days.ago
    expired = Order.where(status: "draft").where("draft_saved_at < ?", cutoff)
    count = expired.count
    expired.destroy_all
    Rails.logger.info "[ExpireDraftsJob] Deleted #{count} expired draft orders (older than #{cutoff})"
  end
end
