# frozen_string_literal: true

# Daily safety-net catalog import — imports all active suppliers' product catalogs
# using the super_admin credential. Staggered 5 minutes apart to avoid overwhelming
# supplier sites.
#
# This is now a low-frequency supplement to per-user list syncing (which is the
# primary data source). It ensures the catalog stays seeded for new users and
# catches products that don't appear on any user's ordering lists.
class StaggeredSupplierImportJob < ApplicationJob
  queue_as :scraping

  def perform
    suppliers = Supplier.active.order(:id).to_a
    return if suppliers.empty?

    super_admin = User.super_admin
    unless super_admin
      Rails.logger.error '[StaggeredSupplierImportJob] No super_admin found in system!'
      ScrapingErrorMailer.no_super_admin.deliver_later
      return
    end

    Rails.logger.info "[StaggeredSupplierImportJob] Starting daily catalog import for #{suppliers.size} suppliers"

    suppliers.each_with_index do |supplier, index|
      credential = super_admin.credential_for(supplier)
      unless credential
        Rails.logger.warn "[StaggeredSupplierImportJob] No credential for #{supplier.name}, skipping"
        next
      end

      if already_running?(supplier)
        Rails.logger.warn "[StaggeredSupplierImportJob] Import already running for #{supplier.name}, skipping"
        next
      end

      log = create_scraping_log(supplier)

      # Stagger 5 minutes apart to avoid overwhelming suppliers
      ImportSupplierProductsJob.set(wait: (index * 5).minutes).perform_later(supplier.id, nil, log.id)
      Rails.logger.info "[StaggeredSupplierImportJob] Queued import for #{supplier.name} in #{index * 5}m (log_id: #{log.id})"
    end
  end

  private

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
