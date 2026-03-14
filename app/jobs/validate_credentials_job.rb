class ValidateCredentialsJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # For PPO (passwordless), this job can run for up to 7 minutes while
  # the scraper polls the DB waiting for the user's verification code.
  # The browser timeout is set to 7 minutes to accommodate the 5-minute code wait.
  retry_on StandardError, attempts: 2, wait: 1.minute

  def perform(credential_id)
    credential = SupplierCredential.find(credential_id)

    Rails.logger.info "[ValidateCredentialsJob] Validating credentials for #{credential.supplier.name} (user: #{credential.user_id})"

    # Sysco: skip the separate validation browser session entirely.
    # SyscoCombinedImportJob opens ONE browser that validates login AND
    # imports catalog + lists in a single session. Sysco's double-login
    # flow makes session restore unreliable between browser instances,
    # so we can't afford to waste a login on validation alone.
    if credential.supplier.code == 'sysco'
      Rails.logger.info "[ValidateCredentialsJob] Sysco — delegating to SyscoCombinedImportJob (single browser session)"
      credential.update_columns(importing: true, import_status_text: 'Validating credentials...')
      SyscoCombinedImportJob.perform_later(credential.id)
      return
    end

    manager = Authentication::SessionManager.new(credential)
    result = manager.validate_credentials

    if result[:valid]
      Rails.logger.info "[ValidateCredentialsJob] Credentials valid for #{credential.supplier.name}"
      credential.mark_active!

      # Flag the credential as importing so the Stimulus polling UI shows
      # "Importing order guides..." while the background jobs run.
      credential.update_columns(importing: true, import_status_text: 'Importing order guides...')

      # Kick off initial imports so the user sees products and lists immediately
      # instead of waiting for the next cron cycle (up to 15 min for products,
      # 24 hours for lists).
      ImportSupplierProductsJob.perform_later(credential.id)
      ImportSupplierListsJob.perform_later(credential.id)
    elsif result[:two_fa_required]
      # For non-polling scrapers, 2FA was requested but handled via exception
      Rails.logger.info "[ValidateCredentialsJob] 2FA required for #{credential.supplier.name}"
      credential.update!(two_fa_enabled: true, status: 'pending')
    else
      Rails.logger.warn "[ValidateCredentialsJob] Credentials invalid for #{credential.supplier.name}: #{result[:message]}"
      credential.mark_failed!(result[:message] || 'Validation failed')
    end
  rescue Authentication::TwoFactorHandler::TwoFactorRequired
    # This shouldn't happen for PPO (it polls inline), but handle it for other scrapers
    Rails.logger.info "[ValidateCredentialsJob] 2FA required (exception) for #{credential.supplier.name}"
    credential.update!(two_fa_enabled: true, status: 'pending')
  rescue Scrapers::BaseScraper::AuthenticationError => e
    Rails.logger.warn "[ValidateCredentialsJob] Auth error: #{e.message}"
    credential.mark_failed!(e.message)
  rescue StandardError => e
    Rails.logger.error "[ValidateCredentialsJob] Unexpected error: #{e.class.name}: #{e.message}"
    Rails.logger.error e.backtrace&.first(5)&.join("\n")
    credential.mark_failed!(e.message)
  end
end
