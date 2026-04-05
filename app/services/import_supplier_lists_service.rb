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

  # Import lists from the supplier. Accepts an optional +scraper:+ parameter to reuse
  # an existing scraper instance (with its browser already open and logged in).
  def call(scraper: nil)
    Rails.logger.info "[ImportLists] Starting list import for #{credential.supplier.name} (credential #{credential.id})"

    scraper ||= credential.supplier.scraper_klass.new(credential)
    scraped_lists = scraper.scrape_lists

    Rails.logger.info "[ImportLists] Scraped #{scraped_lists.size} lists from #{credential.supplier.name}"

    scraped_lists.each do |list_data|
      # Ensure list has a name — some suppliers return lists with blank names
      list_data[:name] = list_data[:name].presence || "#{credential.supplier.name} List #{list_data[:remote_id]}"

      begin
        upsert_list(list_data)
      rescue StandardError => e
        Rails.logger.warn "[ImportLists] Failed to import list '#{list_data[:name]}': #{e.message}"
        results[:errors] << "List '#{list_data[:name]}': #{e.message}"
      end
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
    org = credential.organization || credential.user.current_organization

    # Deduplicate by supplier + organization + remote_list_id (NOT by credential).
    # Multiple users in the same org may have separate credentials for the same
    # supplier — we don't want duplicate list records for the same remote list.
    supplier_list = SupplierList.find_or_initialize_by(
      supplier: credential.supplier,
      organization: org,
      remote_list_id: list_data[:remote_id]
    )

    supplier_list.assign_attributes(
      supplier_credential: credential, # Track which credential last synced this list
      name: list_data[:name],
      list_type: list_data[:list_type] || 'order_guide',
      remote_list_url: list_data[:url],
      sync_status: 'syncing'
    )
    supplier_list.save!
    supplier_list.mark_syncing!

    # Upsert items — pre-load all existing items by SKU to avoid N find_or_initialize_by queries
    items = list_data[:items] || []
    existing_items_by_sku = supplier_list.supplier_list_items.index_by(&:sku)
    seen_skus = Set.new

    items.each do |item_data|
      upsert_item(supplier_list, item_data, existing_items_by_sku, seen_skus)
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

  def upsert_item(supplier_list, item_data, existing_items_by_sku, seen_skus)
    sku = item_data[:sku].to_s.strip
    return if sku.blank?

    seen_skus << sku

    # Use pre-loaded hash instead of per-item DB query
    item = existing_items_by_sku[sku] || supplier_list.supplier_list_items.build(sku: sku)
    is_new = item.new_record?

    # Track price change on existing items before overwriting
    new_price = item_data[:price]
    if !is_new && new_price.present? && item.price.present? && new_price != item.price
      item.previous_price = item.price
      item.price_updated_at = Time.current
    end

    item.assign_attributes(
      name: item_data[:name].to_s.truncate(255),
      price: item_data[:price],
      price_unit: item_data[:price_unit],
      pack_size: item_data[:pack_size],
      piece_price: (item_data[:piece_price].present? && item_data[:piece_price] != item_data[:price]) ? item_data[:piece_price] : nil,
      piece_pack_size: (item_data[:piece_price].present? && item_data[:piece_price] != item_data[:price]) ? item_data[:piece_pack_size] : nil,
      quantity: item_data[:quantity] || 1,
      in_stock: item_data[:in_stock] != false,
      position: item_data[:position] || 0,
      remote_item_id: item_data[:remote_item_id]
    )
    item.save!

    # Safety net: if the scraper didn't detect a per-unit price from the text,
    # check if the numbers make it obvious (e.g., $16.54 for 72 lbs = $0.23/lb)
    infer_per_unit_pricing!(item) if item.price_unit.blank?

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

    # Update price: use estimated case total for per-unit priced items
    # so SupplierProduct.current_price always represents the full case cost.
    effective_price = item.estimated_total_price
    if effective_price.present? && effective_price != sp.current_price
      if sp.current_price.present? && sp.current_price > 0 && extreme_price_change?(sp.current_price, effective_price)
        Rails.logger.warn "[ImportLists] EXTREME price change for #{sp.supplier_name} (SKU: #{sp.supplier_sku}): " \
                          "$#{sp.current_price} -> $#{effective_price} — skipping update"
      else
        attrs[:previous_price] = sp.current_price
        attrs[:current_price] = effective_price
        attrs[:price_updated_at] = Time.current
      end
    end

    # Propagate price_unit so order verification can interpret scraped prices
    attrs[:price_unit] = item.price_unit if item.price_unit != sp.price_unit

    # Update stock status
    attrs[:in_stock] = item.in_stock unless item.in_stock.nil?

    # Update pack_size if present and different
    attrs[:pack_size] = item.pack_size if item.pack_size.present? && item.pack_size != sp.pack_size

    # Propagate piece pricing (CS/PC dual pricing from Chef's Warehouse)
    attrs[:piece_price] = item.piece_price if item.piece_price != sp.piece_price
    attrs[:piece_pack_size] = item.piece_pack_size if item.piece_pack_size != sp.piece_pack_size

    sp.update!(attrs)

    # Reset discontinuation tracking — product is still on the supplier
    sp.record_seen! if sp.consecutive_misses > 0 || sp.discontinued?
  rescue StandardError => e
    Rails.logger.debug "[ImportLists] Error refreshing linked product for SKU #{item.sku}: #{e.message}"
  end

  # Safety-net heuristic: detect per-unit pricing when the scraper couldn't
  # determine it from the price text format (e.g., no "/LB" suffix visible).
  #
  # If the stored price ÷ pack weight gives an unrealistically low per-lb
  # price (< $0.30), the price is almost certainly already per-lb.
  # Detects when a scraped price is per-lb (not a case total) and sets
  # price_unit so estimated_total_price can compute the real case cost.
  #
  # Two strategies:
  # 1. US Foods "LBA" / "OZA" suffixes — these ALWAYS indicate per-piece
  #    average weights on items priced per-lb (meats, seafood, poultry).
  # 2. Fallback heuristic: for lb-based packs ≥ 5 lbs, if implied $/lb < $0.30
  #    the price is almost certainly per-lb, not per-case.
  def infer_per_unit_pricing!(item)
    return unless item.price && item.price >= 2.0

    pack = item.pack_size.to_s

    # Strategy 1: "LBA" (Lb Average) and "OZA" (Oz Average) are US Foods
    # conventions for per-piece weight on protein priced per-lb.
    if pack.match?(/\b(?:LBA|OZA)\b/i)
      item.update_column(:price_unit, "lb")
      Rails.logger.info "[ImportLists] Inferred price_unit=lb (LBA/OZA suffix) for '#{item.name}' " \
                        "($#{item.price}/#{item.pack_size})"
      return
    end

    # Strategy 2: heuristic for lb-based packs
    parsed = UnitParser.parse(pack)
    return unless parsed[:parseable] && parsed[:unit] == "lb" && parsed[:quantity] >= 5

    implied_per_lb = item.price / parsed[:quantity]

    if implied_per_lb < 0.30
      item.update_column(:price_unit, "lb")
      Rails.logger.info "[ImportLists] Inferred price_unit=lb for '#{item.name}' " \
                        "($#{item.price}/#{item.pack_size}, implied $#{'%.2f' % implied_per_lb}/lb)"
    end
  end

  # Guard against extreme price swings from bad supplier API data.
  # Allows normal fluctuations (up to 5x) but blocks obvious errors.
  def extreme_price_change?(old_price, new_price)
    return false if old_price.nil? || old_price <= 0
    ratio = new_price / old_price
    ratio > 5.0 || ratio < 0.2
  end

  def mark_removed_lists(scraped_remote_ids)
    return if scraped_remote_ids.blank?

    org = credential.organization || credential.user.current_organization

    # Scope to supplier+org (matching the deduplication key in upsert_list)
    stale = SupplierList.where(supplier: credential.supplier, organization: org)
                        .where.not(remote_list_id: scraped_remote_ids)
    stale.find_each do |list|
      Rails.logger.info "[ImportLists] List '#{list.name}' no longer found on supplier site"
      # Don't destroy - just mark as stale. The list might come back.
      list.update(sync_status: 'failed', sync_error: 'List no longer found on supplier site')
    end
  end
end
