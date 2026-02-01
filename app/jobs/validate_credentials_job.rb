class ValidateCredentialsJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(credential_id)
    credential = SupplierCredential.find(credential_id)

    Rails.logger.info "[ValidateCredentialsJob] Validating credentials for #{credential.supplier.name} (user: #{credential.user_id})"

    manager = Authentication::SessionManager.new(credential)
    result = manager.validate_credentials

    if result[:valid]
      Rails.logger.info "[ValidateCredentialsJob] Credentials valid"
      credential.mark_active!

      if result[:two_fa_required]
        credential.update!(two_fa_enabled: true)
      end
    else
      Rails.logger.warn "[ValidateCredentialsJob] Credentials invalid: #{result[:message]}"
      credential.mark_failed!(result[:message] || "Validation failed")
    end

    # Notify user of validation result
    CredentialValidationMailer.validation_result(credential, result).deliver_later
  rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
    Rails.logger.info "[ValidateCredentialsJob] 2FA required during validation"
    credential.update!(two_fa_enabled: true)
  rescue => e
    Rails.logger.error "[ValidateCredentialsJob] Validation error: #{e.message}"
    credential.mark_failed!(e.message)
  end
end
