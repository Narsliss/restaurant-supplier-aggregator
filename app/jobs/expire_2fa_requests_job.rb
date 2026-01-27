class Expire2faRequestsJob < ApplicationJob
  queue_as :low

  def perform
    expired_count = Supplier2faRequest
      .where(status: "pending")
      .where("expires_at <= ?", Time.current)
      .update_all(status: "expired")

    Rails.logger.info "[Expire2faRequestsJob] Expired #{expired_count} 2FA requests"
  end
end
