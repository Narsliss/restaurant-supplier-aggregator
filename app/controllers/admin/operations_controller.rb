class Admin::OperationsController < Admin::BaseController
  def show
    suppliers = Supplier.where(active: true).order(:name)
    supplier_ids = suppliers.pluck(:id)

    # Bulk queries for supplier health (avoids N+1 per-supplier loops)
    log_stats = ScrapingLog.where(supplier_id: supplier_ids)
      .where('created_at > ?', 24.hours.ago)
      .group(:supplier_id)
      .pluck(:supplier_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(CASE WHEN status = 'completed' THEN 1 END)"))
      .each_with_object({}) { |(sid, total, completed), h| h[sid] = { total: total, completed: completed } }

    last_scrapes = ScrapingLog.where(supplier_id: supplier_ids)
      .where("id IN (SELECT MAX(id) FROM scraping_logs WHERE supplier_id IN (?) GROUP BY supplier_id)", supplier_ids)
      .index_by(&:supplier_id)

    product_counts = SupplierProduct.where(supplier_id: supplier_ids, discontinued: false)
      .group(:supplier_id).count

    stale_counts = SupplierProduct.where(supplier_id: supplier_ids, discontinued: false)
      .where('last_scraped_at < ?', 7.days.ago)
      .group(:supplier_id).count

    cred_active = SupplierCredential.where(supplier_id: supplier_ids, status: 'active')
      .group(:supplier_id).count

    cred_failed = SupplierCredential.where(supplier_id: supplier_ids, status: %w[failed expired])
      .group(:supplier_id).count

    # Assemble per-supplier health from pre-fetched data
    @supplier_health = suppliers.map do |supplier|
      stats = log_stats[supplier.id] || { total: 0, completed: 0 }
      {
        supplier: supplier,
        last_scrape: last_scrapes[supplier.id],
        success_rate_24h: stats[:total] > 0 ? (stats[:completed].to_f / stats[:total] * 100).round : nil,
        total_products: product_counts[supplier.id] || 0,
        stale_products: stale_counts[supplier.id] || 0,
        active_credentials: cred_active[supplier.id] || 0,
        failed_credentials: cred_failed[supplier.id] || 0
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
