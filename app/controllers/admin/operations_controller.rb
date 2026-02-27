class Admin::OperationsController < Admin::BaseController
  def show
    suppliers = Supplier.where(active: true).order(:name)

    # Per-supplier health
    @supplier_health = suppliers.map do |supplier|
      logs_24h = ScrapingLog.for_supplier(supplier).in_last(24.hours)
      completed_24h = logs_24h.completed.count
      total_24h = logs_24h.count

      {
        supplier: supplier,
        last_scrape: ScrapingLog.last_for_supplier(supplier),
        success_rate_24h: total_24h > 0 ? (completed_24h.to_f / total_24h * 100).round : nil,
        total_products: supplier.supplier_products.where(discontinued: false).count,
        stale_products: supplier.supplier_products.where(discontinued: false).where('last_scraped_at < ?', 7.days.ago).count,
        active_credentials: supplier.supplier_credentials.where(status: 'active').count,
        failed_credentials: supplier.supplier_credentials.where(status: %w[failed expired]).count
      }
    end

    # Credential status breakdown
    @credential_stats = SupplierCredential.group(:status).count

    # Recent scraping logs
    @recent_logs = ScrapingLog.recent.includes(:supplier).limit(15)

    # Recent failures
    @recent_failures = ScrapingLog.failed.recent.includes(:supplier).limit(10)

    # Pending 2FA
    @pending_2fa = Supplier2faRequest.where(status: 'pending')
                     .where('expires_at > ?', Time.current)
                     .includes(supplier_credential: [:supplier, :user])

    # List sync status
    @list_sync_stats = SupplierList.group(:sync_status).count

    # Job queue health
    @queue_stats = {
      pending: SolidQueue::Job.where(finished_at: nil).count,
      failed:  SolidQueue::FailedExecution.count,
      running: SolidQueue::ClaimedExecution.count
    }
  end
end
