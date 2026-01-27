class ScrapeSupplierJob < ApplicationJob
  queue_as :scraping
  
  retry_on StandardError, wait: 5.minutes, attempts: 3
  discard_on ActiveRecord::RecordNotFound

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
    results.each do |result|
      supplier_product = SupplierProduct.find_by(
        supplier: supplier,
        supplier_sku: result[:supplier_sku]
      )

      next unless supplier_product

      supplier_product.update_price!(
        result[:current_price],
        in_stock: result[:in_stock]
      )
    end
  end
end
