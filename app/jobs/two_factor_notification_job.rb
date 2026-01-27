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

    # Could also send SMS or push notification here
    # send_sms_notification(user, request) if user.phone.present?
    # send_push_notification(user, request)
  end

  private

  def send_sms_notification(user, request)
    # Implement SMS notification if needed
    # TwilioService.send_sms(
    #   to: user.phone,
    #   body: "#{request.supplier.name} requires verification. Open the app to enter your code. Expires in #{request.time_remaining / 60} minutes."
    # )
  end
end
