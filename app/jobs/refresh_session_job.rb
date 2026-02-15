# frozen_string_literal: true

class RefreshSessionJob < ApplicationJob
  queue_as :default

  # NO RETRIES for session refresh to avoid 2FA spam
  # If refresh fails, the next import attempt will handle it
  discard_on ActiveRecord::RecordNotFound

  def perform(credential_id = nil)
    if credential_id
      # Refresh specific credential
      credential = SupplierCredential.find(credential_id)
      refresh_credential(credential)
    else
      # This shouldn't happen anymore - use SessionRefreshSchedulerJob instead
      Rails.logger.warn '[RefreshSessionJob] Called without credential_id - use SessionRefreshSchedulerJob instead'
    end
  end

  private

  def refresh_credential(credential)
    return unless credential.needs_refresh?
    return unless credential.active? || credential.expired?

    Rails.logger.info "[RefreshSessionJob] Refreshing session for #{credential.supplier.name} (user: #{credential.user_id})"

    manager = Authentication::SessionManager.new(credential)

    if manager.refresh_session
      Rails.logger.info "[RefreshSessionJob] Session refreshed successfully for #{credential.supplier.name}"
      credential.touch(:last_login_at) # Update timestamp to show session is fresh
    else
      Rails.logger.warn "[RefreshSessionJob] Session refresh failed for #{credential.supplier.name} - credential may need revalidation"
      # Don't mark as expired here - let the health check job handle it
    end
  rescue Authentication::TwoFactorHandler::TwoFactorRequired
    Rails.logger.info "[RefreshSessionJob] 2FA required for #{credential.supplier.name} - manual intervention needed"
    # 2FA notification already sent by SessionManager
    # Don't retry - user needs to handle this manually
  rescue StandardError => e
    Rails.logger.error "[RefreshSessionJob] Refresh failed for #{credential.supplier.name}: #{e.message}"
    # Don't mark as expired or retry - let health check handle it
  end
end
