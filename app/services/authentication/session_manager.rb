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
        # Try soft refresh first (if available) to avoid triggering MFA
        # Soft refresh just validates the existing session without re-authenticating
        if scraper.respond_to?(:soft_refresh)
          if scraper.soft_refresh
            Rails.logger.info "[SessionManager] Soft refresh succeeded for #{credential.supplier.name}"
            return true
          end
          Rails.logger.info "[SessionManager] Soft refresh failed, session expired for #{credential.supplier.name}"
          # Don't fall through to full login - let the user trigger that manually
          # This prevents unexpected MFA prompts from background jobs
          credential.mark_expired!
          return false
        end

        # Fallback to full login for scrapers without soft_refresh
        scraper.login
        true
      rescue Scrapers::BaseScraper::AuthenticationError => e
        Rails.logger.error "[SessionManager] Auth failed for #{credential.supplier.name}: #{e.message}"
        false
      rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
        # 2FA required - session refresh paused pending user input
        Rails.logger.info "[SessionManager] 2FA required for #{credential.supplier.name}"
        raise e
      rescue StandardError => e
        Rails.logger.error "[SessionManager] Session refresh failed: #{e.message}"
        credential.mark_failed!(e.message)
        false
      end
    end

    def validate_credentials
      supplier = credential.supplier
      Rails.logger.info "[SessionManager] Starting validation for #{supplier.name} (login_url: #{supplier.login_url}, scraper: #{supplier.scraper_class}, user: #{credential.username})"

      begin
        scraper = supplier.scraper_klass.new(credential)
      rescue NameError
        Rails.logger.error "[SessionManager] Scraper class not found: #{supplier.scraper_class}"
        return { valid: false, message: "Scraper class '#{supplier.scraper_class}' not found. Please contact support." }
      end

      # Option 2: Try session restore first for known-good credentials
      # This avoids triggering 2FA for suppliers like US Foods that have valid sessions
      if credential.session_valid?
        Rails.logger.info "[SessionManager] Session is valid, attempting restore for #{supplier.name}"
        begin
          if scraper.respond_to?(:soft_refresh)
            if scraper.soft_refresh
              Rails.logger.info "[SessionManager] Soft refresh succeeded for #{supplier.name}"
              return { valid: true, message: 'Credentials validated successfully (session restored)' }
            end
            Rails.logger.info "[SessionManager] Soft refresh failed for #{supplier.name}, falling back to fresh login"
          else
            # Fallback: try full login
            Rails.logger.info "[SessionManager] No soft_refresh available for #{supplier.name}, attempting fresh login"
          end
        rescue StandardError => e
          Rails.logger.info "[SessionManager] Session restore failed for #{supplier.name}: #{e.message}, falling back to fresh login"
        end
      else
        Rails.logger.info "[SessionManager] No valid session for #{supplier.name}, attempting fresh login"
      end

      begin
        scraper.login
        Rails.logger.info "[SessionManager] Login successful for #{supplier.name}"
        { valid: true, message: 'Credentials validated successfully' }
      rescue Scrapers::BaseScraper::AuthenticationError => e
        Rails.logger.warn "[SessionManager] Authentication failed for #{supplier.name}: #{e.message}"
        { valid: false, message: "Authentication failed: #{e.message}" }
      rescue Authentication::TwoFactorHandler::TwoFactorRequired
        Rails.logger.info "[SessionManager] 2FA required for #{supplier.name}"
        { valid: false, two_fa_required: true, message: 'Verification code required' }
      rescue Scrapers::BaseScraper::CaptchaDetectedError
        Rails.logger.warn "[SessionManager] CAPTCHA detected on #{supplier.name}"
        { valid: false,
          message: "CAPTCHA detected on #{supplier.name}'s login page. Please try again later or log in manually." }
      rescue Scrapers::BaseScraper::MaintenanceError
        Rails.logger.warn "[SessionManager] #{supplier.name} site under maintenance"
        { valid: false, message: "#{supplier.name}'s website is currently under maintenance. Please try again later." }
      rescue Scrapers::BaseScraper::ScrapingError => e
        Rails.logger.error "[SessionManager] Scraping error for #{supplier.name}: #{e.message}"
        { valid: false, message: "Could not complete login on #{supplier.name}: #{e.message}" }
      rescue Ferrum::TimeoutError => e
        Rails.logger.error "[SessionManager] Browser timeout for #{supplier.name}: #{e.message}"
        { valid: false,
          message: "#{supplier.name}'s login page took too long to respond. The site may be down or slow. Please try again later." }
      rescue Ferrum::StatusError => e
        Rails.logger.error "[SessionManager] HTTP error for #{supplier.name}: #{e.message}"
        { valid: false,
          message: "#{supplier.name}'s login page returned an error (#{e.message}). The site may be down." }
      rescue Ferrum::BrowserError => e
        Rails.logger.error "[SessionManager] Browser error for #{supplier.name}: #{e.message}"
        { valid: false, message: "Browser error while accessing #{supplier.name}: #{e.message}" }
      rescue StandardError => e
        Rails.logger.error "[SessionManager] Unexpected error for #{supplier.name}: #{e.class.name}: #{e.message}"
        Rails.logger.error e.backtrace&.first(5)&.join("\n")
        { valid: false,
          message: "Unexpected error validating #{supplier.name} credentials: #{e.class.name} — #{e.message}" }
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
      SupplierCredential.where(status: 'pending').find_each do |credential|
        ValidateCredentialsJob.perform_later(credential.id)
      end
    end
  end
end
