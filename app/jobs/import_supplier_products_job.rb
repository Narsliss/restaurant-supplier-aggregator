# frozen_string_literal: true

class ImportSupplierProductsJob < ApplicationJob
  queue_as :scraping

  # NO RETRIES - Email super_admin immediately on failure
  discard_on ActiveRecord::RecordNotFound

  def perform(supplier_id, search_terms = nil, scraping_log_id = nil)
    @supplier = Supplier.find(supplier_id)
    @scraping_log = ScrapingLog.find(scraping_log_id) if scraping_log_id

    # Get super_admin's credential for this supplier
    @credential = find_super_admin_credential

    unless @credential
      handle_no_credential_error
      return
    end

    unless @credential.active? || @credential.status == 'pending' ||
           (@credential.expired? && !@credential.supplier.no_password_required?)
      # Skip expired 2FA suppliers (would trigger unwanted MFA in a background job).
      # Password-based suppliers (CW, WCW) can auto-login, so let them proceed.
      Rails.logger.warn "[ImportProductsJob] Credential ##{@credential.id} status is '#{@credential.status}', skipping import"
      @scraping_log&.mark_cancelled!
      return
    end

    # Mark log as running if we have one
    @scraping_log&.update!(status: 'running', started_at: Time.current)

    @credential.update!(importing: true)

    service = ImportSupplierProductsService.new(@credential)
    results = service.import_catalog(search_terms: search_terms)

    Rails.logger.info "[ImportProductsJob] #{@supplier.name}: imported=#{results[:imported]}, updated=#{results[:updated]}, skipped=#{results[:skipped]}, errors=#{results[:errors].size}"

    # Mark log as completed
    @scraping_log&.mark_completed!(
      product_count: results[:imported],
      products_updated: results[:updated]
    )

    # Update metadata
    @scraping_log&.update!(
      metadata: {
        skipped: results[:skipped],
        errors_count: results[:errors].size,
        error_samples: results[:errors].first(5)
      }
    )
  rescue StandardError => e
    handle_import_error(e)
    raise e # Re-raise to trigger discard, but error is already handled
  ensure
    cleanup_credential if @credential&.persisted?
  end

  private

  def find_super_admin_credential
    super_admin = User.super_admin

    unless super_admin
      Rails.logger.error '[ImportProductsJob] No super_admin found in system!'
      return nil
    end

    super_admin.credential_for(@supplier)
  end

  def handle_no_credential_error
    error_msg = "No super_admin credentials found for #{@supplier.name}"
    Rails.logger.error "[ImportProductsJob] #{error_msg}"

    @scraping_log&.mark_failed!(error_msg)

    # Email super_admin immediately
    ScrapingErrorMailer.no_credentials(@supplier).deliver_later
  end

  def handle_import_error(error)
    error_msg = "Import failed for #{@supplier.name}: #{error.class.name} - #{error.message}"
    Rails.logger.error "[ImportProductsJob] #{error_msg}"
    Rails.logger.error error.backtrace&.first(10)&.join("\n")

    # Mark log as failed
    @scraping_log&.mark_failed!(
      error_msg,
      {
        error_class: error.class.name,
        backtrace: error.backtrace&.first(10)
      }
    )

    # Mark credential as failed
    @credential&.mark_failed!(error_msg)

    # Email super_admin immediately - NO RETRIES
    ScrapingErrorMailer.import_failed(@supplier, error, @credential).deliver_later
  end

  def cleanup_credential
    @credential.update_columns(
      importing: false,
      last_import_at: Time.current,
      import_progress: 0,
      import_total: 0,
      import_status_text: nil
    )
  end
end
