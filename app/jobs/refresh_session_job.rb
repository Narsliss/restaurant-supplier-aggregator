class RefreshSessionJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: 10.minutes, attempts: 2
  discard_on ActiveRecord::RecordNotFound

  def perform(credential_id = nil)
    if credential_id
      # Refresh specific credential
      credential = SupplierCredential.find(credential_id)
      refresh_credential(credential)
    else
      # Refresh all credentials that need it
      refresh_all_stale_credentials
    end
  end

  private

  def refresh_credential(credential)
    return unless credential.needs_refresh?
    return unless credential.active? || credential.expired?

    Rails.logger.info "[RefreshSessionJob] Refreshing session for #{credential.supplier.name} (user: #{credential.user_id})"

    manager = Authentication::SessionManager.new(credential)
    
    if manager.refresh_session
      Rails.logger.info "[RefreshSessionJob] Session refreshed successfully"
    else
      Rails.logger.warn "[RefreshSessionJob] Session refresh failed"
    end
  rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
    Rails.logger.info "[RefreshSessionJob] 2FA required for session refresh"
    # 2FA notification already sent
  rescue => e
    Rails.logger.error "[RefreshSessionJob] Refresh failed: #{e.message}"
    credential.mark_expired!
  end

  def refresh_all_stale_credentials
    # Find credentials that haven't been used recently
    # Skip those that had a recent import (hourly import keeps session alive)
    stale_credentials = SupplierCredential
      .where(status: %w[active expired])
      .where("last_login_at < ? OR last_login_at IS NULL", 6.hours.ago)
      .where("last_import_at < ? OR last_import_at IS NULL", 2.hours.ago)

    Rails.logger.info "[RefreshSessionJob] Found #{stale_credentials.count} credentials to refresh"

    stale_credentials.find_each do |credential|
      # Queue individual refresh jobs to spread the load
      RefreshSessionJob.perform_later(credential.id)
    end
  end
end
