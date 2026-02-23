# One-time backfill: enqueue category backfill on next deploy if needed.
# Safe to leave in place — the job is a no-op once all products are categorized.
Rails.application.config.after_initialize do
  if defined?(SolidQueue) && ENV["PROCESS_TYPE"] == "worker"
    uncategorized = Product.where(category: [nil, ""]).count rescue 0
    if uncategorized > 100
      Rails.logger.info "[Backfill] #{uncategorized} uncategorized products found, enqueuing BackfillProductCategoriesJob"
      BackfillProductCategoriesJob.perform_later
    end
  end
rescue => e
  Rails.logger.warn "[Backfill] Skipped auto-enqueue: #{e.message}"
end
