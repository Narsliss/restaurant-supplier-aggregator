# Orchestrates scraping supplier lists/order guides and upserting
# SupplierList + SupplierListItem records.
#
# Usage:
#   service = ImportSupplierListsService.new(credential)
#   result = service.call
#   # => { lists_synced: 2, items_imported: 142, items_updated: 38 }
#
class ImportSupplierListsService
  # US Foods regenerates the account order guide under a new OG-<number>
  # remote id roughly monthly (observed: OG-814669 → OG-824039 → OG-833572 →
  # OG-843511 → OG-853237, Apr–Aug 2026). The guide's contents — and the
  # items' SKUs — stay the same; only the container id rotates. Keying lists
  # strictly by remote_list_id turned each rotation into a brand-new
  # SupplierList whose items could never rejoin their own product matches
  # (one-item-per-supplier-per-match), so every generation appended a fresh
  # copy of the guide to the org's matched list.
  ROTATED_GUIDE_PATTERN = /\AOG-\d+\z/

  # An orphaned list must share at least this fraction of the incoming
  # guide's SKUs to be adopted as its predecessor. Guards against adopting
  # an unrelated guide (e.g., a second department's OG) that merely vanished
  # from the same scrape.
  SUCCESSOR_MIN_SKU_OVERLAP = 0.3

  # UnitParser reports Sysco's "#" packs under their own unit key; it means
  # pounds, same as "lb".
  POUND_UNITS = %w[lb #].freeze

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

    # Known before any upsert so successor detection can tell "rotated away"
    # from "still present" (a predecessor is only adoptable if its remote id
    # is absent from the current scrape).
    @scraped_remote_ids = scraped_lists.map { |l| l[:remote_id] }.compact

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

    # Onboarding headstart: first successful import for a new location seeds
    # an order list from the chef's recent supplier activity. Guarded inside
    # the service (idempotent, never touches locations with curated lists),
    # so this is a no-op on routine daily syncs.
    SeedOrderListsService.new(credential).call if results[:lists_synced] > 0

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

    # Deduplicate by supplier + organization + location + remote_list_id.
    # Two users at the same restaurant share one list (same location_id).
    # Two restaurants in the same org each keep their own list — even when the
    # supplier-side scrape returns the same remote_id (some scrapers like WCW
    # and PPO use a static "order-guide" label, which would otherwise collapse
    # every location into one row and lose per-location items).
    supplier_list = SupplierList.find_or_initialize_by(
      supplier: credential.supplier,
      organization: org,
      location_id: credential.location_id,
      remote_list_id: list_data[:remote_id]
    )

    # Rotated-guide adoption: an unseen OG-* id may be last month's guide
    # under a new number. Adopting the predecessor row (instead of creating
    # a sibling) keeps its SupplierListItems — and therefore every
    # ProductMatchItem and chef decision hanging off them — alive across
    # the rotation; only genuinely new SKUs flow to incremental matching.
    if supplier_list.new_record?
      predecessor = rotated_predecessor(list_data, org)
      if predecessor
        Rails.logger.info "[ImportLists] Adopting '#{predecessor.name}' (#{predecessor.remote_list_id}) " \
                          "as predecessor of rotated guide #{list_data[:remote_id]}"
        supplier_list = predecessor
      end
    end

    supplier_list.assign_attributes(
      remote_list_id: list_data[:remote_id],
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

    # Drop a stale wrong-SKU link before linking. Legacy SLIs created via
    # the old name-fallback linker can end up pointed at an off-by-one
    # neighbor SP. Without this, link_to_supplier_product! short-circuits
    # on the existing link and the SLI stays stranded — for stock display
    # this means the SLI inherits the wrong neighbor's in_stock state
    # forever, even when WCW's order guide reports the right SKU as live.
    if item.supplier_product_id.present? && item.sku.present?
      linked_sp = item.supplier_product
      if linked_sp && item.sku.to_s.strip != linked_sp.supplier_sku.to_s.strip
        item.update_columns(supplier_product_id: nil)
      end
    end

    # Try to link to an existing SupplierProduct by SKU (or create a stub
    # if the catalog hasn't scraped this SKU yet).
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
    #
    # Exception: when we also propagate a per-weight price_unit below (a
    # catch-weight "$5.46/LB" quote), storing the case total under that unit
    # would double-convert — SupplierProduct#per_unit_price divides by the unit
    # factor, so a case total tagged 'LB' reads as a per-pound price 16x too
    # high. The catalog importer and VerifyItemPriceJob both cache the price as
    # quoted, per its unit; match them and let callers convert.
    effective_price = if per_weight_unit?(item.price_unit)
      item.effective_price
    else
      item.estimated_total_price
    end
    if effective_price.present? && effective_price != sp.current_price
      if sp.current_price.present? && sp.current_price > 0 &&
         extreme_price_change?(sp.current_price, effective_price, item.pack_size.presence || sp.pack_size)
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

    # Update stock status. SupplierListItem#in_stock is a delegating method
    # that READS from supplier_product.in_stock (because the catalog is
    # usually fresher than the order guide); using that method here would
    # copy the SP's value back to itself — a no-op. We need the SLI's own
    # raw column, which upsert_item just set from the order-guide API's
    # `unavailable` flag. Without this, WCW (and any case_pricing supplier
    # whose catalog returns nil for stock) had no path to flip SP.in_stock
    # back to true once it ever went false.
    list_item_stock = item.read_attribute(:in_stock)
    attrs[:in_stock] = list_item_stock unless list_item_stock.nil?

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
    # "#" is pounds — Sysco writes its packs that way ("2x6#", "1x10#AVG"), so
    # gating on "lb" alone skipped most of their catch-weight catalogue.
    parsed = UnitParser.parse(pack)
    return unless parsed[:parseable] && POUND_UNITS.include?(parsed[:unit]) && parsed[:quantity] >= 5

    implied_per_lb = item.price / parsed[:quantity]

    if implied_per_lb < 0.30
      item.update_column(:price_unit, "lb")
      Rails.logger.info "[ImportLists] Inferred price_unit=lb for '#{item.name}' " \
                        "($#{item.price}/#{item.pack_size}, implied $#{'%.2f' % implied_per_lb}/lb)"
    end
  end

  # True when the price is quoted per unit of weight or volume ("$5.46/LB")
  # rather than for the whole pack ("CS", "EA").
  def per_weight_unit?(unit)
    return false if unit.blank?

    key = UnitParser.normalize_unit_key(unit)
    UnitParser::WEIGHT_TO_OZ.key?(key) || UnitParser::VOLUME_TO_FL_OZ.key?(key)
  end

  # Guard against extreme price swings from bad supplier API data.
  # Allows normal fluctuations (up to 5x) but blocks obvious errors.
  #
  # A per-unit price being corrected to a case total is the one big jump that
  # is legitimate: a catch-weight item stored at $13.69/lb becomes a $136.90
  # case, and the ratio is the pack weight. Blocking those froze the wrong
  # (low) figure in place permanently — the item then undercut every competitor
  # by 10-20x and no later import could repair it. Let the correction through
  # when the new price lands on the pack multiple.
  def extreme_price_change?(old_price, new_price, pack_size = nil)
    return false if old_price.nil? || old_price <= 0
    ratio = new_price / old_price
    return false if ratio > 5.0 && pack_multiple?(ratio, pack_size)

    ratio > 5.0 || ratio < 0.2
  end

  # Does this ratio match the pack's own size — i.e. is it price-per-unit
  # becoming price-per-case rather than a bad number?
  PACK_MULTIPLE_TOLERANCE = 0.02

  def pack_multiple?(ratio, pack_size)
    parsed = UnitParser.parse(pack_size.to_s)
    return false unless parsed[:parseable]

    quantity = parsed[:quantity].to_f
    return false unless quantity > 0

    (ratio - quantity).abs <= quantity * PACK_MULTIPLE_TOLERANCE
  end

  # Find the SupplierList this rotated guide succeeds, or nil.
  #
  # Candidates: same supplier/org/location, rotation-pattern remote id,
  # absent from the current scrape (still-present lists are never adopted).
  # Among candidates, pick the one whose items best overlap the incoming
  # guide's SKUs — content, not recency, identifies the predecessor when
  # several stale generations have accumulated. Zero/weak overlap means a
  # genuinely different guide: create a new row rather than adopt.
  def rotated_predecessor(list_data, org)
    remote_id = list_data[:remote_id].to_s
    return nil unless remote_id.match?(ROTATED_GUIDE_PATTERN)

    incoming_skus = (list_data[:items] || []).map { |i| i[:sku].to_s.strip }.reject(&:blank?).to_set
    return nil if incoming_skus.empty?

    absent_ids = @scraped_remote_ids || [remote_id]
    candidates = SupplierList.where(
      supplier: credential.supplier,
      organization: org,
      location_id: credential.location_id
    ).where.not(remote_list_id: absent_ids)
     .select { |sl| sl.remote_list_id.to_s.match?(ROTATED_GUIDE_PATTERN) }
    return nil if candidates.empty?

    best, best_overlap = candidates.map { |sl|
      skus = sl.supplier_list_items.pluck(:sku).map { |s| s.to_s.strip }.to_set
      denom = [incoming_skus.size, skus.size].min
      overlap = denom.zero? ? 0.0 : (incoming_skus & skus).size.to_f / denom
      [sl, overlap]
    }.max_by { |_, overlap| overlap }

    return nil if best_overlap < SUCCESSOR_MIN_SKU_OVERLAP

    Rails.logger.info "[ImportLists] Successor match: #{remote_id} overlaps " \
                      "#{(best_overlap * 100).round}% with #{best.remote_list_id}"
    best
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
