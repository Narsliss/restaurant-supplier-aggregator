class ScrapeSupplierJob < ApplicationJob
  queue_as :scraping

  # Selective retries: only retry transient browser/network errors
  retry_on Ferrum::TimeoutError, wait: 2.minutes, attempts: 2
  retry_on Ferrum::ProcessTimeoutError, wait: 2.minutes, attempts: 2
  retry_on Ferrum::DeadBrowserError, wait: 2.minutes, attempts: 2
  discard_on ActiveRecord::RecordNotFound
  discard_on Scrapers::BaseScraper::AuthenticationError

  def perform(supplier_id, credential_id = nil)
    supplier = Supplier.find(supplier_id)

    credentials = if credential_id
      [SupplierCredential.find(credential_id)]
    else
      SupplierCredential.where(supplier: supplier, status: "active")
    end

    if credentials.empty?
      Rails.logger.warn "[ScrapeSupplierJob] No active credentials for #{supplier.name}"
      return
    end

    credentials.each do |credential|
      scrape_for_credential(supplier, credential)
    end
  end

  private

  def scrape_for_credential(supplier, credential)
    scraper = supplier.scraper_klass.new(credential)

    # Get SKUs to scrape based on user's order lists
    skus = get_skus_for_user(supplier, credential.user)

    if skus.empty?
      Rails.logger.info "[ScrapeSupplierJob] No SKUs to scrape for #{supplier.name} (user: #{credential.user_id})"
      return
    end

    Rails.logger.info "[ScrapeSupplierJob] Scraping #{skus.count} SKUs from #{supplier.name}"

    begin
      results = scraper.scrape_prices(skus)
      update_prices(supplier, results)
      Rails.logger.info "[ScrapeSupplierJob] Updated #{results.count} prices for #{supplier.name}"
    rescue Scrapers::BaseScraper::AuthenticationError => e
      Rails.logger.error "[ScrapeSupplierJob] Auth failed for #{supplier.name}: #{e.message}"
      credential.mark_failed!(e.message)
    rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
      Rails.logger.info "[ScrapeSupplierJob] 2FA required for #{supplier.name}"
      # 2FA notification is already sent by the handler
    rescue => e
      Rails.logger.error "[ScrapeSupplierJob] Scraping failed for #{supplier.name}: #{e.message}"
      raise # Let retry mechanism handle it
    end
  end

  def get_skus_for_user(supplier, user)
    user.order_list_items
      .joins(product: :supplier_products)
      .where(supplier_products: { supplier_id: supplier.id })
      .pluck("supplier_products.supplier_sku")
      .uniq
  end

  def update_prices(supplier, results)
    # Pre-load all matching products in a single query instead of N find_by calls
    skus = results.map { |r| r[:supplier_sku] }.compact
    products_by_sku = SupplierProduct.where(supplier: supplier, supplier_sku: skus).index_by(&:supplier_sku)

    results.each do |result|
      supplier_product = products_by_sku[result[:supplier_sku]]
      next unless supplier_product

      supplier_product.update_price!(
        result[:current_price],
        in_stock: result[:in_stock]
      )
    end
  end
end
