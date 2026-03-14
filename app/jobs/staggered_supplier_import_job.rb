# frozen_string_literal: true

# Daily safety-net catalog import — imports all active suppliers' product catalogs
# using any active credential in the system. Staggered 5 minutes apart to avoid
# overwhelming supplier sites. Runs once daily at 5 AM.
#
# This is a low-frequency supplement to per-user list syncing (which is the
# primary data source). It ensures the catalog stays seeded for new users and
# catches products that don't appear on any user's ordering lists.
#
# Credential selection: picks the most recently logged-in active credential for
# each supplier, preferring ones with valid sessions to minimize re-authentication.
class StaggeredSupplierImportJob < ApplicationJob
  queue_as :scraping

  def perform
    suppliers = Supplier.active.order(:id).to_a
    return if suppliers.empty?

    Rails.logger.info "[StaggeredSupplierImportJob] Starting daily catalog import for #{suppliers.size} suppliers"

    queued = 0
    suppliers.each_with_index do |supplier, index|
      credential = best_credential_for(supplier)
      unless credential
        Rails.logger.warn "[StaggeredSupplierImportJob] No active credential for #{supplier.name}, skipping"
        next
      end

      if already_running?(supplier)
        Rails.logger.warn "[StaggeredSupplierImportJob] Import already running for #{supplier.name}, skipping"
        next
      end

      log = create_scraping_log(supplier)

      # Sysco: use combined job (catalog + lists in one browser session) since
      # session restore doesn't work and we don't want 2 separate logins.
      if supplier.code == 'sysco'
        SyscoCombinedImportJob.set(wait: (queued * 5).minutes).perform_later(credential.id)
      else
        ImportSupplierProductsJob.set(wait: (queued * 5).minutes).perform_later(supplier.id, credential.id, log.id)
      end
      Rails.logger.info "[StaggeredSupplierImportJob] Queued import for #{supplier.name} using credential #{credential.id} (#{credential.user.email}) in #{queued * 5}m"
      queued += 1
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

  # Pick the best active credential for a supplier: prefer ones with valid sessions
  # (to avoid re-authentication overhead), then fall back to most recently logged in.
  def best_credential_for(supplier)
    active_creds = SupplierCredential.where(supplier: supplier, status: 'active')
    return nil unless active_creds.exists?

    # Prefer credentials with a valid session (avoids needing to re-login)
    with_session = active_creds.select(&:session_valid?)
    candidates = with_session.any? ? with_session : active_creds.to_a

    # Pick the most recently used credential
    candidates.max_by { |c| c.last_login_at || c.created_at }
  end

  def already_running?(supplier)
    ScrapingLog
      .for_supplier(supplier)
      .running
      .where('started_at > ?', 5.minutes.ago)
      .exists?
  end
end
