class ScrapePricesJob < ApplicationJob
  queue_as :scraping

  def perform(supplier_id = nil)
    suppliers = if supplier_id
      [Supplier.find(supplier_id)]
    else
      Supplier.active
    end

    suppliers.each do |supplier|
      # Queue individual supplier scraping jobs
      ScrapeSupplierJob.perform_later(supplier.id)
    end

    Rails.logger.info "[ScrapePricesJob] Queued price scraping for #{suppliers.count} supplier(s)"
  end
end
