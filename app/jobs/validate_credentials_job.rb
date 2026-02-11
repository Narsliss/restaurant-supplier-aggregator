class ValidateCredentialsJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # For PPO (passwordless), this job can run for up to 5 minutes while
  # the scraper polls the DB waiting for the user's verification code.
  retry_on StandardError, attempts: 2, wait: 1.minute

  def perform(credential_id)
    credential = SupplierCredential.find(credential_id)

    Rails.logger.info "[ValidateCredentialsJob] Validating credentials for #{credential.supplier.name} (user: #{credential.user_id})"

    manager = Authentication::SessionManager.new(credential)
    result = manager.validate_credentials

    if result[:valid]
      Rails.logger.info "[ValidateCredentialsJob] Credentials valid for #{credential.supplier.name}"
      credential.mark_active!
    elsif result[:two_fa_required]
      # For non-polling scrapers, 2FA was requested but handled via exception
      Rails.logger.info "[ValidateCredentialsJob] 2FA required for #{credential.supplier.name}"
      credential.update!(two_fa_enabled: true, status: "pending")
    else
      Rails.logger.warn "[ValidateCredentialsJob] Credentials invalid for #{credential.supplier.name}: #{result[:message]}"
      credential.mark_failed!(result[:message] || "Validation failed")
    end
  rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
    # This shouldn't happen for PPO (it polls inline), but handle it for other scrapers
    Rails.logger.info "[ValidateCredentialsJob] 2FA required (exception) for #{credential.supplier.name}"
    credential.update!(two_fa_enabled: true, status: "pending")
  rescue Scrapers::BaseScraper::AuthenticationError => e
    Rails.logger.warn "[ValidateCredentialsJob] Auth error: #{e.message}"
    credential.mark_failed!(e.message)
  rescue => e
    Rails.logger.error "[ValidateCredentialsJob] Unexpected error: #{e.class.name}: #{e.message}"
    Rails.logger.error e.backtrace&.first(5)&.join("\n")
    credential.mark_failed!(e.message)
  end
end
