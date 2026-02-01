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
      supplier = credential.supplier
      Rails.logger.info "[SessionManager] Starting validation for #{supplier.name} (login_url: #{supplier.login_url}, scraper: #{supplier.scraper_class}, user: #{credential.username})"

      begin
        scraper = supplier.scraper_klass.new(credential)
      rescue NameError => e
        Rails.logger.error "[SessionManager] Scraper class not found: #{supplier.scraper_class}"
        return { valid: false, message: "Scraper class '#{supplier.scraper_class}' not found. Please contact support." }
      end

      begin
        scraper.login
        Rails.logger.info "[SessionManager] Login successful for #{supplier.name}"
        { valid: true, message: "Credentials validated successfully" }
      rescue Scrapers::BaseScraper::AuthenticationError => e
        Rails.logger.warn "[SessionManager] Authentication failed for #{supplier.name}: #{e.message}"
        { valid: false, message: "Authentication failed: #{e.message}" }
      rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
        Rails.logger.info "[SessionManager] 2FA required for #{supplier.name}"
        { valid: true, message: "Credentials valid (2FA required)", two_fa_required: true }
      rescue Scrapers::BaseScraper::CaptchaDetectedError => e
        Rails.logger.warn "[SessionManager] CAPTCHA detected on #{supplier.name}"
        { valid: false, message: "CAPTCHA detected on #{supplier.name}'s login page. Please try again later or log in manually." }
      rescue Scrapers::BaseScraper::MaintenanceError => e
        Rails.logger.warn "[SessionManager] #{supplier.name} site under maintenance"
        { valid: false, message: "#{supplier.name}'s website is currently under maintenance. Please try again later." }
      rescue Scrapers::BaseScraper::ScrapingError => e
        Rails.logger.error "[SessionManager] Scraping error for #{supplier.name}: #{e.message}"
        { valid: false, message: "Could not complete login on #{supplier.name}: #{e.message}" }
      rescue Ferrum::TimeoutError => e
        Rails.logger.error "[SessionManager] Browser timeout for #{supplier.name}: #{e.message}"
        { valid: false, message: "#{supplier.name}'s login page took too long to respond. The site may be down or slow. Please try again later." }
      rescue Ferrum::StatusError => e
        Rails.logger.error "[SessionManager] HTTP error for #{supplier.name}: #{e.message}"
        { valid: false, message: "#{supplier.name}'s login page returned an error (#{e.message}). The site may be down." }
      rescue Ferrum::BrowserError => e
        Rails.logger.error "[SessionManager] Browser error for #{supplier.name}: #{e.message}"
        { valid: false, message: "Browser error while accessing #{supplier.name}: #{e.message}" }
      rescue => e
        Rails.logger.error "[SessionManager] Unexpected error for #{supplier.name}: #{e.class.name}: #{e.message}"
        Rails.logger.error e.backtrace&.first(5)&.join("\n")
        { valid: false, message: "Unexpected error validating #{supplier.name} credentials: #{e.class.name} — #{e.message}" }
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
