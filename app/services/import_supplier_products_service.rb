class ImportSupplierProductsService
  attr_reader :supplier, :credential, :results

  # Minimum number of products a scrape must return before we trust it enough
  # to record misses for unseen products. This prevents a failed/partial scrape
  # from incorrectly incrementing miss counters on the entire catalog.
  MINIMUM_SCRAPE_THRESHOLD = 50

  # Minimum percentage of existing products that must be seen in a scrape before
  # we record misses for the unseen ones. A catalog scrape that only finds 5% of
  # existing products is clearly a partial scan — not evidence that the other 95%
  # were discontinued. Set high enough to prevent category-browsing partial scrapes
  # from penalizing the full catalog.
  MINIMUM_SEEN_PERCENTAGE = 60

  def initialize(credential)
    @credential = credential
    @supplier = credential.supplier
    @results = { imported: 0, updated: 0, skipped: 0, errors: [], discontinued: 0, reinstated: 0 }
  end

  # Import products from the supplier's catalog by searching for common food categories.
  #
  # Products are written to the DB incrementally as they're scraped (not all at the end).
  # This means:
  #   - Users see products appearing in real-time in the UI
  #   - If the scraper crashes halfway, everything scraped so far is kept
  #   - Memory stays flat (no giant array accumulating thousands of products)
  # Import products from the supplier's catalog by searching for common food categories.
  # Accepts an optional +scraper:+ parameter to reuse an existing scraper instance
  # (with its browser already open and logged in). When omitted, a new scraper is created.
  def import_catalog(search_terms: nil, scraper: nil)
    search_terms ||= default_search_terms

    Rails.logger.info "[ImportProducts] Starting catalog import for #{supplier.name} with #{search_terms.size} search terms"

    # Pre-load indexes BEFORE scraping starts so we can write incrementally
    @existing_by_sku = SupplierProduct
                       .where(supplier: supplier)
                       .index_by(&:supplier_sku)
    all_products = Product.select(:id, :name, :normalized_name).to_a
    @product_index = build_product_index(all_products)
    @items_processed = 0
    @seen_skus = Set.new

    credential.update_columns(import_status_text: "Searching #{supplier.name} catalog...")

    begin
      scraper ||= supplier.scraper_klass.new(credential)

      # Pass a block for incremental DB writes — the scraper yields batches
      # as each page/search is scraped instead of accumulating everything.
      # Scrapers that support &on_batch will yield and return [].
      # Scrapers that don't will ignore the block and return the full array.
      catalog_items = scraper.scrape_catalog(search_terms) do |batch|
        import_batch(batch)
      end

      # If the scraper returned items (doesn't support incremental yields),
      # fall back to batch processing
      if catalog_items.is_a?(Array) && catalog_items.any?
        Rails.logger.info "[ImportProducts] Batch mode: processing #{catalog_items.size} items from #{supplier.name}"
        import_batch(catalog_items)
      end
    rescue Scrapers::BaseScraper::AuthenticationError => e
      credential.mark_failed!(e.message)
      results[:errors] << "Authentication failed: #{e.message}"
      return results
    rescue StandardError => e
      results[:errors] << "Scraping failed: #{e.class.name} — #{e.message}"
      Rails.logger.error "[ImportProducts] Scraping failed for #{supplier.name}: #{e.message}"
      # Don't return early — we may have already imported products incrementally
    end

    # After scraping, identify products that were NOT seen in this import.
    # Only do this if we scraped enough products to trust the results —
    # a partial/failed scrape shouldn't penalize the entire catalog.
    record_misses_for_unseen_products

    Rails.logger.info "[ImportProducts] #{supplier.name} import complete: " \
                      "#{results[:imported]} imported, #{results[:updated]} updated, " \
                      "#{results[:skipped]} skipped, #{results[:discontinued]} discontinued, " \
                      "#{results[:reinstated]} reinstated"
    results
  end

  # Refresh pricing for all known (non-discontinued) SKUs that weren't seen in
  # the term-based catalog scrape. Uses the scraper's direct ID lookup
  # (scraper#refresh_known_skus) — currently only Sysco implements this.
  #
  # This closes the coverage gap where term-based search misses niche products
  # that don't match any of the generic search terms. SKUs that come back with
  # data get last_scraped_at bumped + price refreshed; SKUs not returned get
  # added to consecutive_misses tracking via the normal record_misses path.
  def refresh_known_products(scraper:)
    unless scraper.respond_to?(:refresh_known_skus)
      Rails.logger.info "[ImportProducts] #{supplier.name} scraper doesn't support refresh_known_skus, skipping"
      return { updated: 0, missed: 0 }
    end

    @existing_by_sku ||= SupplierProduct.where(supplier: supplier).index_by(&:supplier_sku)
    @seen_skus ||= Set.new

    skus_to_refresh = @existing_by_sku.values
                                       .reject(&:discontinued)
                                       .map(&:supplier_sku)
                                       .reject { |s| s.blank? || @seen_skus.include?(s) }

    if skus_to_refresh.empty?
      Rails.logger.info "[ImportProducts] No additional known SKUs to refresh for #{supplier.name}"
      return { updated: 0, missed: 0 }
    end

    Rails.logger.info "[ImportProducts] Refreshing #{skus_to_refresh.size} known #{supplier.name} SKUs via direct ID lookup"
    credential.update_columns(import_status_text: "Refreshing #{skus_to_refresh.size} known products...")

    total_updated = 0
    total_missed = 0

    scraper.refresh_known_skus(skus_to_refresh) do |result|
      apply_refresh_updates(result[:updates])
      total_updated += result[:updates].size
      total_missed += result[:missed].size
      result[:updates].each { |u| @seen_skus.add(u[:supplier_sku]) }
    end

    Rails.logger.info "[ImportProducts] #{supplier.name} refresh complete: #{total_updated} updated, #{total_missed} missed"
    { updated: total_updated, missed: total_missed }
  end

  # Import a batch of scraped items into the DB immediately.
  # Called by the scraper via the block passed to scrape_catalog.
  #
  # Uses a two-path approach for performance:
  #   - Existing products: bulk upsert via upsert_all (one SQL per batch)
  #   - New products: individual saves (need find_or_create_product matching)
  def import_batch(items)
    now = Time.current
    update_rows = []
    new_items = []
    category_backfills = []

    items.each do |item|
      next if item[:supplier_sku].blank? || item[:supplier_name].blank?
      next if @seen_skus.include?(item[:supplier_sku])

      @seen_skus.add(item[:supplier_sku])
      @items_processed += 1

      existing = @existing_by_sku[item[:supplier_sku]]
      if existing
        row = build_update_row(item, existing, now, category_backfills)
        update_rows << row if row
      else
        new_items << item
      end
    end

    # BULK path: upsert all existing product updates in one SQL statement
    bulk_upsert_existing(update_rows) if update_rows.any?

    # Reverse sync: propagate updated catalog prices to linked SupplierListItems
    # so matched list prices stay fresh between order guide syncs.
    sync_prices_to_list_items(update_rows) if update_rows.any?

    # INDIVIDUAL path: new products need find_or_create_product matching
    new_items.each do |item|
      import_new_item(item)
    end

    # Batch category backfills
    backfill_categories(category_backfills) if category_backfills.any?

    # Progress update (once per batch, not every 25 items)
    credential.update_columns(
      import_progress: @items_processed,
      import_total: 0,
      import_status_text: "Imported #{@items_processed} products so far..."
    )
    Rails.logger.info "[ImportProducts] #{supplier.name}: #{@items_processed} products processed (#{results[:imported]} new, #{results[:updated]} updated)"
  end

  private

  # Catalog imports run with a super_admin credential that may have different
  # location/delivery context than individual users. Stock availability is
  # location-specific, so catalog imports should never downgrade in_stock
  # from true to false — only the per-user order guide sync (ImportSupplierListsService)
  # has the right context to mark items out of stock.
  #
  # Rules:
  #   nil (scraper didn't set it)  → preserve existing
  #   true                         → upgrade: mark in stock
  #   false                        → preserve existing (don't downgrade)
  def resolve_stock_status(scraped_stock, existing_stock)
    return existing_stock if scraped_stock.nil?
    return true if scraped_stock == true
    # scraped_stock is false — don't downgrade, preserve existing
    existing_stock
  end

  # Build a hash for an existing product update (no DB call).
  def build_update_row(item, existing, now, category_backfills)
    row = {
      id: existing.id,
      supplier_id: existing.supplier_id,
      supplier_sku: existing.supplier_sku,
      supplier_name: item[:supplier_name],
      last_scraped_at: now,
      current_price: existing.current_price,
      previous_price: existing.previous_price,
      pack_size: item[:pack_size].present? ? item[:pack_size] : existing.pack_size,
      supplier_url: item[:supplier_url].present? ? item[:supplier_url] : existing.supplier_url,
      in_stock: resolve_stock_status(item[:in_stock], existing.in_stock),
      price_updated_at: existing.price_updated_at,
      piece_price: item[:piece_price].present? ? item[:piece_price] : existing.piece_price,
      piece_pack_size: item[:piece_pack_size].present? ? item[:piece_pack_size] : existing.piece_pack_size,
      consecutive_misses: existing.consecutive_misses,
      discontinued: existing.discontinued,
      discontinued_at: existing.discontinued_at
    }

    # Price change detection
    if item[:current_price].present? && item[:current_price] != existing.current_price
      row[:previous_price] = existing.current_price
      row[:current_price] = item[:current_price]
      row[:price_updated_at] = now
    end

    # Reinstatement
    if existing.consecutive_misses > 0 || existing.discontinued?
      row[:consecutive_misses] = 0
      if existing.discontinued?
        row[:discontinued] = false
        row[:discontinued_at] = nil
        results[:reinstated] += 1
        Rails.logger.info "[ImportProducts] Reinstated #{item[:supplier_name]} (SKU: #{item[:supplier_sku]}) — reappeared in catalog"
      end
    end

    results[:updated] += 1

    # Track category backfill needed
    if existing.product_id && existing.product&.category.blank?
      category_backfills << { product_id: existing.product_id, item: item }
    end

    row
  rescue StandardError => e
    results[:errors] << "#{item[:supplier_name]}: #{e.message}"
    Rails.logger.warn "[ImportProducts] Error building update for #{item[:supplier_sku]}: #{e.message}"
    nil
  end

  # Bulk upsert existing products in one SQL statement.
  def bulk_upsert_existing(rows)
    return if rows.empty?

    SupplierProduct.upsert_all(
      rows,
      unique_by: %i[supplier_id supplier_sku],
      update_only: %i[
        supplier_name current_price previous_price pack_size
        supplier_url in_stock price_updated_at last_scraped_at
        piece_price piece_pack_size consecutive_misses
        discontinued discontinued_at
      ]
    )
  end

  # Apply price/timestamp refreshes for SKUs returned by direct ID lookup.
  # Only touches price-related columns + last_scraped_at + miss counters —
  # name/pack_size/category/url stay as-is since the refresh API doesn't
  # return them. Reinstates discontinued products that reappeared.
  def apply_refresh_updates(updates)
    return if updates.empty?

    now = Time.current
    rows = []

    updates.each do |item|
      existing = @existing_by_sku[item[:supplier_sku]]
      next unless existing

      new_price = item[:current_price]
      price_changed = new_price.present? && new_price != existing.current_price
      reinstating = existing.discontinued?

      rows << {
        id: existing.id,
        supplier_id: existing.supplier_id,
        supplier_sku: existing.supplier_sku,
        last_scraped_at: now,
        current_price: price_changed ? new_price : existing.current_price,
        previous_price: price_changed ? existing.current_price : existing.previous_price,
        price_updated_at: price_changed ? now : existing.price_updated_at,
        price_unit: item[:price_unit].presence || existing.price_unit,
        consecutive_misses: 0,
        discontinued: reinstating ? false : existing.discontinued,
        discontinued_at: reinstating ? nil : existing.discontinued_at
      }

      results[:updated] += 1 if price_changed
      if reinstating
        results[:reinstated] += 1
        Rails.logger.info "[ImportProducts] Reinstated SKU #{existing.supplier_sku} via refresh — reappeared upstream"
      end
    end

    return if rows.empty?

    SupplierProduct.upsert_all(
      rows,
      unique_by: %i[supplier_id supplier_sku],
      update_only: %i[
        last_scraped_at current_price previous_price price_updated_at
        price_unit consecutive_misses discontinued discontinued_at
      ]
    )

    sync_prices_to_list_items(rows)
  end

  # Propagate updated catalog prices to linked SupplierListItems so matched
  # list prices stay current between order guide syncs. Uses update_columns
  # to avoid callbacks and prevent loops with the forward sync in
  # ImportSupplierListsService#refresh_linked_product.
  def sync_prices_to_list_items(update_rows)
    sp_ids = update_rows.map { |r| r[:id] }.compact
    return if sp_ids.empty?

    updated_count = 0

    SupplierProduct.where(id: sp_ids).includes(:supplier_list_items).find_each do |sp|
      sp.supplier_list_items.each do |sli|
        next if sli.price == sp.current_price && sli.read_attribute(:in_stock) == sp.in_stock

        attrs = {}

        if sli.price != sp.current_price && sp.current_price.present?
          attrs[:previous_price] = sli.price
          attrs[:price] = sp.current_price
          attrs[:price_updated_at] = sp.price_updated_at || Time.current
        end

        if sli.read_attribute(:in_stock) != sp.in_stock
          attrs[:in_stock] = sp.in_stock
        end

        next if attrs.empty?

        sli.update_columns(attrs)
        updated_count += 1
      end
    end

    if updated_count > 0
      Rails.logger.info "[ImportProducts] Reverse sync: updated #{updated_count} list items from catalog prices"
    end
  end

  # Import a single new product (needs product matching).
  def import_new_item(item)
    return if item[:supplier_sku].blank? || item[:supplier_name].blank?

    supplier_product = SupplierProduct.new(
      supplier: supplier,
      supplier_sku: item[:supplier_sku],
      supplier_name: item[:supplier_name],
      current_price: item[:current_price],
      pack_size: item[:pack_size],
      piece_price: item[:piece_price],
      piece_pack_size: item[:piece_pack_size],
      supplier_url: item[:supplier_url],
      in_stock: item[:in_stock] != false,
      price_updated_at: item[:current_price].present? ? Time.current : nil,
      last_scraped_at: Time.current
    )

    product = find_or_create_product(item, @product_index)
    supplier_product.product = product if product

    if supplier_product.save
      @existing_by_sku[item[:supplier_sku]] = supplier_product
      results[:imported] += 1
    else
      results[:errors] << "#{item[:supplier_name]}: #{supplier_product.errors.full_messages.join(', ')}"
    end
  rescue StandardError => e
    results[:errors] << "#{item[:supplier_name]}: #{e.message}"
    Rails.logger.warn "[ImportProducts] Error importing new #{item[:supplier_sku]}: #{e.message}"
  end

  # Batch category backfills using update_columns (no callbacks).
  def backfill_categories(backfills)
    backfills.each do |entry|
      product = Product.find_by(id: entry[:product_id])
      next unless product && product.category.blank?

      item = entry[:item]
      cat = item[:category]
      unless cat.present?
        result = AiProductCategorizer.rule_based_categorize(item[:supplier_name])
        cat = result[:category] if result[:confidence] >= 0.7
      end
      product.update_columns(category: cat, subcategory: item[:subcategory]) if cat.present?
    end
  end

  # Build an in-memory index of products keyed by the first word of normalized_name.
  # Also keeps a hash by exact normalized_name for O(1) exact match lookups.
  def build_product_index(products)
    by_name = {}
    by_first_word = Hash.new { |h, k| h[k] = [] }

    products.each do |product|
      next if product.normalized_name.blank?

      by_name[product.normalized_name.downcase] = product

      first_word = product.normalized_name.split.first&.downcase
      by_first_word[first_word] << product if first_word
    end

    { by_name: by_name, by_first_word: by_first_word }
  end

  # Try to match an existing Product by name, or create a new one.
  # Uses the pre-built in-memory index instead of per-item DB queries.
  def find_or_create_product(item, product_index)
    normalizer = ProductNormalizer.new(item[:supplier_name], pack_size: item[:pack_size])
    canonical = normalizer.canonical_name

    return nil if canonical.blank?

    # Exact match via hash lookup (O(1) instead of DB query)
    exact = product_index[:by_name][canonical.downcase]
    return exact if exact

    # Similarity matching using in-memory index
    first_word = canonical.split.first&.downcase
    if first_word.present?
      # Get candidates from the first-word index (replaces 2 LIKE queries)
      candidates = product_index[:by_first_word][first_word] || []

      # Also check candidates containing the first word in any position
      # (equivalent to the old "%first_word%" LIKE query but in-memory)
      all_candidates = candidates.dup
      product_index[:by_first_word].each do |word, products|
        all_candidates.concat(products) if word != first_word && word.include?(first_word)
      end
      all_candidates.uniq!

      # Find best match above threshold (0.75 to avoid false positives on
      # products that differ only by size/count like 21-25 vs 26-30 shrimp)
      best_match = nil
      best_score = 0.0

      all_candidates.each do |candidate|
        score = ProductNormalizer.similarity(item[:supplier_name], candidate.name)
        if score > best_score && score >= 0.75
          best_score = score
          best_match = candidate
        end
      end

      return best_match if best_match

      # Fallback: try base_name comparison (more aggressively stripped)
      if canonical.split.size >= 2
        base = ProductNormalizer.new(item[:supplier_name]).base_name.downcase
        all_candidates.each do |candidate|
          candidate_base = ProductNormalizer.new(candidate.name).base_name.downcase
          return candidate if base == candidate_base
        end
      end
    end

    # No match found - create a new canonical product
    display_name = canonical.split.map(&:capitalize).join(' ')
    categorization = AiProductCategorizer.rule_based_categorize(item[:supplier_name])

    new_product = Product.create!(
      name: display_name,
      normalized_name: canonical.downcase.gsub(/[^a-z0-9\s]/, '').squish,
      category: item[:category] || categorization[:category],
      subcategory: item[:subcategory] || categorization[:subcategory]
    )

    # Add the new product to the in-memory index so subsequent items can match it
    normalized = new_product.normalized_name.downcase
    product_index[:by_name][normalized] = new_product
    fw = normalized.split.first
    product_index[:by_first_word][fw] << new_product if fw

    new_product
  end

  # After a full catalog import, diff seen SKUs against existing DB records.
  # Products that were in the DB but NOT seen in this scrape get their
  # consecutive_misses counter incremented. Once the threshold is reached,
  # the product is marked as discontinued.
  #
  # Safety: we skip this entirely if the scrape returned too few products,
  # which suggests a partial failure rather than genuine catalog changes.
  def record_misses_for_unseen_products
    total_seen = @seen_skus.size
    total_existing = @existing_by_sku.size

    # Safety check 1: absolute minimum
    if total_seen < MINIMUM_SCRAPE_THRESHOLD
      Rails.logger.info "[ImportProducts] Skipping miss tracking for #{supplier.name} — " \
                        "only #{total_seen} products seen (threshold: #{MINIMUM_SCRAPE_THRESHOLD})"
      return
    end

    # Safety check 2: percentage-based — if the scrape only covers a small fraction
    # of existing products, it's a partial scan (e.g., category browsing) not a full
    # catalog check. Don't penalize unseen products.
    if total_existing > 0
      seen_pct = (total_seen.to_f / total_existing * 100).round(1)
      if seen_pct < MINIMUM_SEEN_PERCENTAGE
        Rails.logger.info "[ImportProducts] Skipping miss tracking for #{supplier.name} — " \
                          "only #{seen_pct}% of catalog seen (#{total_seen}/#{total_existing}, " \
                          "threshold: #{MINIMUM_SEEN_PERCENTAGE}%)"
        return
      end
    end

    unseen_skus = @existing_by_sku.keys - @seen_skus.to_a

    if unseen_skus.empty?
      Rails.logger.info "[ImportProducts] All #{total_existing} existing products were seen in scrape for #{supplier.name}"
      return
    end

    Rails.logger.info "[ImportProducts] #{supplier.name}: #{unseen_skus.size} existing products not seen in this scrape (#{total_seen} seen)"

    # Bulk update for efficiency — split into increment-only vs discontinue
    unseen_products = unseen_skus.filter_map { |sku| @existing_by_sku[sku] }
    return if unseen_products.empty?

    # Safety: only count one miss per day per product. Multiple imports in the
    # same day (e.g., testing, manual refreshes) should not stack misses.
    # Filter to products that haven't already been missed today.
    today = Date.current
    unseen_products = unseen_products.reject do |p|
      p.last_missed_at.present? && p.last_missed_at.to_date == today
    end

    if unseen_products.empty?
      Rails.logger.info "[ImportProducts] #{supplier.name}: all unseen products already missed today — skipping"
      return
    end

    # Products that will be discontinued (reached miss threshold)
    to_discontinue_ids = unseen_products.select do |p|
      (p.consecutive_misses + 1) >= SupplierProduct::DISCONTINUE_AFTER_MISSES && !p.discontinued
    end.map(&:id)

    # Products that just need miss counter incremented
    to_increment_ids = unseen_products.reject do |p|
      (p.consecutive_misses + 1) >= SupplierProduct::DISCONTINUE_AFTER_MISSES && !p.discontinued
    end.map(&:id)

    # Bulk increment miss counter for non-discontinue products
    if to_increment_ids.any?
      SupplierProduct.where(id: to_increment_ids)
        .update_all("consecutive_misses = consecutive_misses + 1, last_missed_at = '#{Time.current.iso8601}'")
    end

    # Bulk discontinue products that hit the threshold
    if to_discontinue_ids.any?
      SupplierProduct.where(id: to_discontinue_ids).update_all(
        "consecutive_misses = consecutive_misses + 1, " \
        "discontinued = true, " \
        "discontinued_at = '#{Time.current.iso8601}', " \
        "last_missed_at = '#{Time.current.iso8601}', " \
        "in_stock = false"
      )
      results[:discontinued] += to_discontinue_ids.size
      Rails.logger.info "[ImportProducts] Discontinued #{to_discontinue_ids.size} products for #{supplier.name}"
    end
  end

  def default_search_terms
    # Search terms chosen to maximize product coverage across all suppliers.
    # Each term targets a distinct product category or common ingredient.
    %w[
      chicken beef pork salmon shrimp
      lettuce tomato onion potato
      cheese butter cream milk
      oil flour sugar rice pasta
      turkey bacon sausage
      lobster tilapia tuna crab cod
      mushroom pepper garlic
      broccoli squash avocado spinach
      celery carrot lemon lime apple
      bread tortilla
      sauce vinegar mustard ketchup mayonnaise
      coffee juice tea
      egg yogurt frozen
      seasoning cinnamon
      honey chocolate vanilla
      lamb veal duck
      bean corn cucumber herb
      dried smoked fresh whole
      strawberry blueberry raspberry
      walnut pecan almond
      wrap napkin glove container
      mozzarella parmesan cheddar provolone
      olive capers anchovy
      ham prosciutto salami pepperoni
      scallop oyster clam mussel
      catfish halibut mahi swordfish
      wing thigh breast tender
      waffle fries chips
      dough pizza crust
      syrup jam jelly
      plate bowl cup lid
      foil pan tray liner
      soap sanitizer cleaner towel
    ]
  end
end
