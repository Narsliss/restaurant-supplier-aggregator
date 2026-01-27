module Authentication
  class SessionManager
    attr_reader :credential

    def initialize(credential)
      @credential = credential
    end

    def refresh_session
      return false unless credential.present?

      scraper = credential.supplier.scraper_klass.new(credential)
      
      begin
        scraper.login
        true
      rescue Scrapers::BaseScraper::AuthenticationError => e
        Rails.logger.error "[SessionManager] Auth failed for #{credential.supplier.name}: #{e.message}"
        false
      rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
        # 2FA required - session refresh paused pending user input
        Rails.logger.info "[SessionManager] 2FA required for #{credential.supplier.name}"
        raise e
      rescue => e
        Rails.logger.error "[SessionManager] Session refresh failed: #{e.message}"
        credential.mark_failed!(e.message)
        false
      end
    end

    def validate_credentials
      scraper = credential.supplier.scraper_klass.new(credential)
      
      begin
        scraper.login
        { valid: true, message: "Credentials validated successfully" }
      rescue Scrapers::BaseScraper::AuthenticationError => e
        { valid: false, message: e.message }
      rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
        { valid: true, message: "Credentials valid (2FA required)", two_fa_required: true }
      rescue => e
        { valid: false, message: "Validation failed: #{e.message}" }
      end
    end

    def session_valid?
      credential.session_valid?
    end

    def needs_refresh?
      credential.needs_refresh?
    end

    def clear_session
      credential.clear_session!
    end

    def self.refresh_all_sessions
      SupplierCredential.active.needs_refresh.find_each do |credential|
        RefreshSessionJob.perform_later(credential.id)
      end
    end

    def self.validate_all_pending
      SupplierCredential.where(status: "pending").find_each do |credential|
        ValidateCredentialsJob.perform_later(credential.id)
      end
    end
  end
end
