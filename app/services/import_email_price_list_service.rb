# Imports products from a parsed InboundPriceList into a SupplierList.
# Follows the same upsert pattern as ImportSupplierListsService but reads
# from the review form params instead of scraping.
#
# Usage:
#   service = ImportEmailPriceListService.new(price_list, supplier, products, location)
#   result = service.call
#   # => { items_imported: 80, items_updated: 38, errors: [] }
#
class ImportEmailPriceListService
  attr_reader :price_list, :supplier, :products, :location, :results

  def initialize(price_list, supplier, products, location)
    @price_list = price_list
    @supplier = supplier
    @products = products # Array of hashes from form params
    @location = location
    @results = { items_imported: 0, items_updated: 0, errors: [] }
  end

  def call
    org = supplier.organization

    # Find or create the SupplierList for this email supplier + org
    supplier_list = SupplierList.find_or_initialize_by(
      supplier: supplier,
      organization: org,
      remote_list_id: "email-#{supplier.id}"
    )

    supplier_list.assign_attributes(
      name: supplier.name,
      list_type: 'managed',
      supplier_credential: nil,
      inbound_price_list: price_list,
      location: location,
      sync_status: 'syncing'
    )
    supplier_list.save!

    # Upsert items
    existing_items_by_sku = supplier_list.supplier_list_items.index_by(&:sku)
    seen_skus = Set.new

    products.each_with_index do |product_data, index|
      upsert_item(supplier_list, product_data, existing_items_by_sku, seen_skus, index)
    end

    # Track items missing from this import (staleness)
    track_missing_items(supplier_list, seen_skus)

    supplier_list.update!(
      sync_status: 'synced',
      sync_error: nil,
      last_synced_at: Time.current,
      product_count: seen_skus.size
    )

    Rails.logger.info "[ImportEmailPriceList] Imported #{results[:items_imported]} new, " \
                      "#{results[:items_updated]} updated for #{supplier.name}"

    results
  rescue StandardError => e
    Rails.logger.error "[ImportEmailPriceList] Error: #{e.class}: #{e.message}"
    results[:errors] << e.message
    results
  end

  private

  def upsert_item(supplier_list, product_data, existing_items_by_sku, seen_skus, position)
    raw_sku = product_data['sku'].to_s.strip
    if raw_sku.blank?
      # Generate a unique SKU from the product name to avoid collisions
      name_slug = product_data['name'].to_s.parameterize[0..20]
      sku = "email-#{name_slug}-#{position}"
    else
      # Append position suffix if this SKU was already seen (duplicates in PDF)
      sku = seen_skus.include?(raw_sku) ? "#{raw_sku}-#{position}" : raw_sku
    end

    seen_skus << sku

    item = existing_items_by_sku[sku] || supplier_list.supplier_list_items.build(sku: sku)
    is_new = item.new_record?

    # Track price changes
    new_price = product_data['price'].to_f
    if !is_new && new_price > 0 && item.price.present? && new_price != item.price
      item.previous_price = item.price
      item.price_updated_at = Time.current
    end

    item.assign_attributes(
      name: product_data['name'].to_s.truncate(255),
      price: new_price > 0 ? new_price : nil,
      pack_size: product_data['pack_size'],
      in_stock: true,
      position: position
    )
    item.save!

    # Link to SupplierProduct (creates if needed)
    item.link_to_supplier_product! if item.supplier_product_id.nil?

    # Propagate price/stock to linked SupplierProduct
    refresh_linked_product(item) if item.supplier_product_id.present?

    if is_new
      results[:items_imported] += 1
    else
      results[:items_updated] += 1
    end
  rescue StandardError => e
    Rails.logger.debug "[ImportEmailPriceList] Error upserting item SKU #{sku}: #{e.message}"
    results[:errors] << "Item '#{product_data['name']}': #{e.message}"
  end

  # Same pattern as ImportSupplierListsService#refresh_linked_product
  def refresh_linked_product(item)
    sp = item.supplier_product
    return unless sp

    attrs = { last_scraped_at: Time.current }

    effective_price = item.estimated_total_price
    if effective_price.present? && effective_price != sp.current_price
      attrs[:previous_price] = sp.current_price
      attrs[:current_price] = effective_price
      attrs[:price_updated_at] = Time.current
    end

    attrs[:in_stock] = item.in_stock
    attrs[:pack_size] = item.pack_size if item.pack_size.present?

    sp.update!(attrs)
    sp.record_seen! if sp.consecutive_misses > 0 || sp.discontinued?
  rescue StandardError => e
    Rails.logger.debug "[ImportEmailPriceList] Error refreshing linked product for SKU #{item.sku}: #{e.message}"
  end

  # Unlike web scrapers where a "miss" could be a scraping error, email PDFs are
  # authoritative — if a product isn't on the list, it's not available to order.
  # Mark missing items as out of stock and discontinued immediately.
  def track_missing_items(supplier_list, seen_skus)
    return if seen_skus.empty?

    missing = supplier_list.supplier_list_items.where.not(sku: seen_skus.to_a)
    missing.find_each do |item|
      item.update!(in_stock: false)
      next unless item.supplier_product

      item.supplier_product.update!(
        in_stock: false,
        discontinued: true,
        discontinued_at: Time.current
      )
    end

    if missing.any?
      Rails.logger.info "[ImportEmailPriceList] Marked #{missing.count} items as unavailable (not on latest PDF)"
    end
  end
end
