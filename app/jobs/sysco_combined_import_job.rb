# frozen_string_literal: true

# Combined validation + import job for Sysco — uses GraphQL API for all data
# operations. Browser is only needed for initial login (SSO + optional 2FA).
#
# Architecture:
# 1. Check if stored API tokens (JWT + syy-authorization) are still valid
# 2. If expired, open browser → login → capture tokens → close browser
# 3. All catalog search, pricing, and list operations use direct HTTP calls
#    to gateway-api.shop.sysco.com/graphql — no Chrome process needed
#
# This eliminates Chrome from runtime for data operations, solving the
# memory/scale issue (600-6000 chefs can't each have a Chrome process).
# JWT tokens have 7-day expiry, so browser login is rare.
class SyscoCombinedImportJob < ApplicationJob
  queue_as :scraping
  limits_concurrency to: 1, key: ->(credential_id) { "sysco_combined_#{credential_id}" }

  retry_on StandardError, attempts: 2, wait: 1.minute
  discard_on ActiveRecord::RecordNotFound

  def perform(credential_id)
    @credential = SupplierCredential.find(credential_id)
    @supplier = @credential.supplier

    Rails.logger.info "[SyscoCombinedImport] Starting combined validate+import for #{@supplier.name} (credential #{credential_id})"

    unless @credential.active? || @credential.status == 'pending'
      Rails.logger.warn "[SyscoCombinedImport] Credential #{credential_id} status '#{@credential.status}', skipping"
      return
    end

    @credential.update_columns(importing: true, import_status_text: 'Checking Sysco session...')

    scraper = @supplier.scraper_klass.new(@credential)

    # ensure_api_session! checks JWT expiry and only opens a browser if needed
    scraper.send(:ensure_api_session!)
    Rails.logger.info "[SyscoCombinedImport] API session ready for #{@supplier.name}"
    @credential.mark_active!

    # Catalog import — direct GraphQL HTTP calls, no browser
    begin
      Rails.logger.info '[SyscoCombinedImport] Starting catalog import via API...'
      @credential.update_columns(import_status_text: 'Importing products...')
      products_service = ImportSupplierProductsService.new(@credential)
      @products_result = products_service.import_catalog(scraper: scraper)
      Rails.logger.info "[SyscoCombinedImport] Catalog: imported=#{@products_result[:imported]}, updated=#{@products_result[:updated]}"
    rescue StandardError => e
      Rails.logger.error "[SyscoCombinedImport] Catalog import failed: #{e.class}: #{e.message}"
    end

    # List import — direct GraphQL HTTP calls, no browser
    begin
      Rails.logger.info '[SyscoCombinedImport] Starting list import via API...'
      @credential.update_columns(import_status_text: 'Importing order guides...')
      lists_service = ImportSupplierListsService.new(@credential)
      @lists_result = lists_service.call(scraper: scraper)
      Rails.logger.info "[SyscoCombinedImport] Lists: #{@lists_result}"
    rescue StandardError => e
      Rails.logger.error "[SyscoCombinedImport] List import failed: #{e.class}: #{e.message}"
    end

    # Delivery dates — direct GraphQL call, no browser
    begin
      Rails.logger.info '[SyscoCombinedImport] Fetching available delivery dates...'
      available_dates = scraper.fetch_available_delivery_days(shipping_condition: 0)
      if available_dates.any?
        @credential.update_columns(
          available_delivery_dates: available_dates,
          delivery_dates_fetched_at: Time.current
        )
        Rails.logger.info "[SyscoCombinedImport] Delivery dates: #{available_dates.size} dates stored (#{available_dates.first}..#{available_dates.last})"
      end
    rescue StandardError => e
      Rails.logger.warn "[SyscoCombinedImport] Delivery dates fetch failed: #{e.class}: #{e.message}"
    end

    Rails.logger.info "[SyscoCombinedImport] Combined import complete for #{@supplier.name}"
  rescue Scrapers::BaseScraper::AuthenticationError => e
    Rails.logger.warn "[SyscoCombinedImport] Auth failed: #{e.message}"
    @credential&.mark_failed!(e.message)
  rescue StandardError => e
    Rails.logger.error "[SyscoCombinedImport] Fatal error: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace&.first(10)&.join("\n")
    @credential&.mark_failed!(e.message)
    raise
  ensure
    if @credential&.persisted?
      @credential.update_columns(
        importing: false,
        last_import_at: Time.current,
        import_progress: 0,
        import_total: 0,
        import_status_text: nil
      )
    end
  end
end
