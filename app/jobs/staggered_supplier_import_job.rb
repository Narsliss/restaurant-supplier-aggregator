# frozen_string_literal: true

# Staggers imports across suppliers every 15 minutes
# Each supplier gets imported once per hour, rotated through the schedule
class StaggeredSupplierImportJob < ApplicationJob
  queue_as :scraping

  # Run every 15 minutes via recurring.yml
  # Rotates through suppliers: Supplier 1 at :00, Supplier 2 at :15, etc.
  def perform
    suppliers = Supplier.active.order(:id).to_a
    return if suppliers.empty?

    current_minute = Time.current.min
    supplier_index = determine_supplier_index(current_minute, suppliers.size)
    supplier = suppliers[supplier_index]

    return unless supplier

    Rails.logger.info "[StaggeredSupplierImportJob] Starting import for #{supplier.name} (schedule slot #{supplier_index + 1}/#{suppliers.size})"

    # Create a scraping log entry
    log = create_scraping_log(supplier)

    # Check if super_admin exists
    super_admin = User.super_admin
    unless super_admin
      error_msg = 'No super_admin found in system! Cannot perform import.'
      Rails.logger.error "[StaggeredSupplierImportJob] #{error_msg}"
      log.mark_failed!(error_msg)
      ScrapingErrorMailer.no_super_admin.deliver_later
      return
    end

    # Check if super_admin has credentials for this supplier
    credential = super_admin.credential_for(supplier)
    unless credential
      error_msg = "Super admin has no credentials for #{supplier.name}"
      Rails.logger.error "[StaggeredSupplierImportJob] #{error_msg}"
      log.mark_failed!(error_msg)
      ScrapingErrorMailer.no_credentials(supplier).deliver_later
      return
    end

    # Check if another import is already running for this supplier
    if already_running?(supplier)
      Rails.logger.warn "[StaggeredSupplierImportJob] Import already running for #{supplier.name}, skipping"
      log.mark_cancelled!
      return
    end

    # Queue the actual import job
    ImportSupplierProductsJob.perform_later(supplier.id, nil, log.id)

    Rails.logger.info "[StaggeredSupplierImportJob] Queued import job for #{supplier.name} (log_id: #{log.id})"
  end

  private

  def determine_supplier_index(current_minute, supplier_count)
    # 0-14 min  -> supplier 0
    # 15-29 min -> supplier 1
    # 30-44 min -> supplier 2
    # 45-59 min -> supplier 3
    # If more suppliers, rotate back to 0
    (current_minute / 15) % supplier_count
  end

  def create_scraping_log(supplier)
    ScrapingLog.create!(
      supplier: supplier,
      job_id: job_id,
      status: 'pending'
    )
  end

  def already_running?(supplier)
    ScrapingLog
      .for_supplier(supplier)
      .running
      .where('started_at > ?', 5.minutes.ago)
      .exists?
  end
end
