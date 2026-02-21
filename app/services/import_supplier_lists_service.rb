# Orchestrates scraping supplier lists/order guides and upserting
# SupplierList + SupplierListItem records.
#
# Usage:
#   service = ImportSupplierListsService.new(credential)
#   result = service.call
#   # => { lists_synced: 2, items_imported: 142, items_updated: 38 }
#
class ImportSupplierListsService
  attr_reader :credential, :results

  def initialize(credential)
    @credential = credential
    @results = { lists_synced: 0, items_imported: 0, items_updated: 0, errors: [] }
  end

  def call
    Rails.logger.info "[ImportLists] Starting list import for #{credential.supplier.name} (credential #{credential.id})"

    scraper = credential.supplier.scraper_klass.new(credential)
    scraped_lists = scraper.scrape_lists

    Rails.logger.info "[ImportLists] Scraped #{scraped_lists.size} lists from #{credential.supplier.name}"

    scraped_lists.each do |list_data|
      upsert_list(list_data)
    end

    # Mark any lists NOT in the scraped data as stale (they may have been deleted on the supplier site)
    mark_removed_lists(scraped_lists.map { |l| l[:remote_id] })

    Rails.logger.info "[ImportLists] Complete: #{results}"
    results
  rescue Scrapers::BaseScraper::AuthenticationError => e
    Rails.logger.error "[ImportLists] Auth failed for credential #{credential.id}: #{e.message}"
    results[:errors] << "Authentication failed: #{e.message}"
    credential.mark_failed!(e.message)
    results
  rescue StandardError => e
    Rails.logger.error "[ImportLists] Error importing lists for credential #{credential.id}: #{e.class}: #{e.message}"
    results[:errors] << "#{e.class}: #{e.message}"
    results
  end

  private

  def upsert_list(list_data)
    # Find or create the SupplierList record
    supplier_list = SupplierList.find_or_initialize_by(
      supplier_credential: credential,
      remote_list_id: list_data[:remote_id]
    )

    supplier_list.assign_attributes(
      supplier: credential.supplier,
      organization: credential.organization || credential.user.current_organization,
      name: list_data[:name],
      list_type: list_data[:list_type] || 'order_guide',
      remote_list_url: list_data[:url],
      sync_status: 'syncing'
    )
    supplier_list.save!
    supplier_list.mark_syncing!

    # Upsert items
    items = list_data[:items] || []
    existing_skus = supplier_list.supplier_list_items.pluck(:sku).compact.to_set
    seen_skus = Set.new

    items.each do |item_data|
      upsert_item(supplier_list, item_data, existing_skus, seen_skus)
    end

    # Remove items no longer in the list
    if seen_skus.any?
      removed = supplier_list.supplier_list_items.where.not(sku: seen_skus.to_a)
      removed_count = removed.count
      removed.destroy_all
      if removed_count > 0
        Rails.logger.info "[ImportLists] Removed #{removed_count} items no longer in '#{supplier_list.name}'"
      end
    end

    supplier_list.mark_synced!
    results[:lists_synced] += 1
  rescue StandardError => e
    Rails.logger.error "[ImportLists] Error upserting list '#{list_data[:name]}': #{e.message}"
    supplier_list&.mark_failed!(e.message)
    results[:errors] << "List '#{list_data[:name]}': #{e.message}"
  end

  def upsert_item(supplier_list, item_data, _existing_skus, seen_skus)
    sku = item_data[:sku].to_s.strip
    return if sku.blank?

    seen_skus << sku

    item = supplier_list.supplier_list_items.find_or_initialize_by(sku: sku)
    is_new = item.new_record?

    item.assign_attributes(
      name: item_data[:name].to_s.truncate(255),
      price: item_data[:price],
      pack_size: item_data[:pack_size],
      quantity: item_data[:quantity] || 1,
      in_stock: item_data[:in_stock] != false,
      position: item_data[:position] || 0,
      remote_item_id: item_data[:remote_item_id]
    )
    item.save!

    # Try to link to an existing SupplierProduct by SKU
    item.link_to_supplier_product! if item.supplier_product_id.nil?

    # Propagate latest list data (price, stock, last_scraped_at) to the linked product
    refresh_linked_product(item) if item.supplier_product_id.present?

    if is_new
      results[:items_imported] += 1
    else
      results[:items_updated] += 1
    end
  rescue StandardError => e
    Rails.logger.debug "[ImportLists] Error upserting item SKU #{sku}: #{e.message}"
  end

  # Propagate list item data to the linked SupplierProduct so list syncing
  # keeps products "alive" in the discontinuation lifecycle and prices current.
  def refresh_linked_product(item)
    sp = item.supplier_product
    return unless sp

    attrs = { last_scraped_at: Time.current }

    # Update price if the list has a newer/different price
    if item.price.present? && item.price != sp.current_price
      attrs[:previous_price] = sp.current_price
      attrs[:current_price] = item.price
      attrs[:price_updated_at] = Time.current
    end

    # Update stock status
    attrs[:in_stock] = item.in_stock unless item.in_stock.nil?

    # Update pack_size if present and different
    attrs[:pack_size] = item.pack_size if item.pack_size.present? && item.pack_size != sp.pack_size

    sp.update!(attrs)

    # Reset discontinuation tracking — product is still on the supplier
    sp.record_seen! if sp.consecutive_misses > 0 || sp.discontinued?
  rescue StandardError => e
    Rails.logger.debug "[ImportLists] Error refreshing linked product for SKU #{item.sku}: #{e.message}"
  end

  def mark_removed_lists(scraped_remote_ids)
    return if scraped_remote_ids.blank?

    stale = credential.supplier_lists.where.not(remote_list_id: scraped_remote_ids)
    stale.find_each do |list|
      Rails.logger.info "[ImportLists] List '#{list.name}' no longer found on supplier site"
      # Don't destroy - just mark as stale. The list might come back.
      list.update(sync_status: 'failed', sync_error: 'List no longer found on supplier site')
    end
  end
end
