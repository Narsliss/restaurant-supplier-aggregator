class ScheduledImportJob < ApplicationJob
  queue_as :scraping

  # This job runs on a cron schedule (hourly) and queues import jobs for all
  # active credentials. This serves two purposes:
  # 1. Keeps product catalog data fresh with current prices and availability
  # 2. Keeps supplier sessions alive to avoid repeated MFA re-authentication
  #
  # Each credential gets its own ImportSupplierProductsJob so they run
  # independently and don't block each other.
  def perform
    credentials = SupplierCredential.where(status: "active")

    Rails.logger.info "[ScheduledImportJob] Found #{credentials.count} active credentials to import"

    credentials.find_each do |credential|
      # Skip if already importing (previous job still running)
      if credential.importing?
        Rails.logger.info "[ScheduledImportJob] Skipping #{credential.supplier.name} (user #{credential.user_id}) — already importing"
        next
      end

      # Skip if imported very recently (within last 30 minutes) to avoid redundant work
      if credential.last_import_at.present? && credential.last_import_at > 30.minutes.ago
        Rails.logger.info "[ScheduledImportJob] Skipping #{credential.supplier.name} (user #{credential.user_id}) — imported #{((Time.current - credential.last_import_at) / 60).round}m ago"
        next
      end

      Rails.logger.info "[ScheduledImportJob] Queuing import for #{credential.supplier.name} (user #{credential.user_id})"
      ImportSupplierProductsJob.perform_later(credential.id)
    end
  end
end
