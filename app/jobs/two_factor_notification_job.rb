class TwoFactorNotificationJob < ApplicationJob
  queue_as :critical

  discard_on ActiveRecord::RecordNotFound

  def perform(request_id)
    request = Supplier2faRequest.find(request_id)

    # Don't send notification if request is no longer pending
    return unless request.pending?

    user = request.user
    supplier = request.supplier

    Rails.logger.info "[TwoFactorNotificationJob] Sending 2FA notification to user #{user.id} for #{supplier.name}"

    # Send email notification
    TwoFactorMailer.code_required(request).deliver_later
  end
end
