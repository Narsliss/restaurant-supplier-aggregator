class ParsePriceListJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 30.seconds, attempts: 2

  def perform(inbound_price_list_id, email_supplier_id: nil, location_id: nil)
    price_list = InboundPriceList.find(inbound_price_list_id)
    return if price_list.imported? # Idempotency guard — already fully processed

    # Parse the PDF if not already parsed
    unless price_list.parsed? || price_list.needs_review?
      result = PdfParsingService.new(price_list).call
      return unless result[:success]
    end

    # Auto-import all products unless the parse looks suspicious
    return unless email_supplier_id && location_id

    supplier = Supplier.find_by(id: email_supplier_id)
    location = Location.find_by(id: location_id)
    return unless supplier && location

    products = price_list.raw_products_json['products'] || []

    if sanity_check_failed?(products, price_list)
      price_list.update!(status: 'needs_review')
      Rails.logger.warn "[ParsePriceList] Sanity check failed for #{price_list.pdf_file_name} — flagging for review"
      return
    end

    # Auto-import all products
    product_params = products.map do |p|
      { 'sku' => p['sku'], 'name' => p['name'], 'price' => p['price'],
        'pack_size' => p['pack_size'], 'category' => p['category'] }
    end

    import_result = ImportEmailPriceListService.new(price_list, supplier, product_params, location).call
    Rails.logger.info "[ParsePriceList] Auto-imported #{import_result[:items_imported]} new, " \
                      "#{import_result[:items_updated]} updated for #{supplier.name}"

    price_list.update!(status: 'imported')
  end

  private

  # Flag for manual review if the parse looks wrong
  def sanity_check_failed?(products, price_list)
    # No products extracted at all
    return true if products.empty?

    # More than half the products have no name
    nameless = products.count { |p| p['name'].to_s.strip.blank? }
    return true if nameless > products.size / 2

    # More than 80% of products have no price (unless it's a small list)
    priceless = products.count { |p| p['price'].nil? }
    return true if products.size > 5 && priceless > products.size * 0.8

    false
  end
end
