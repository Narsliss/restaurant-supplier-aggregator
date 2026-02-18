class ImportSupplierProductsService
  attr_reader :supplier, :credential, :results

  # Minimum number of products a scrape must return before we trust it enough
  # to record misses for unseen products. This prevents a failed/partial scrape
  # from incorrectly incrementing miss counters on the entire catalog.
  MINIMUM_SCRAPE_THRESHOLD = 50

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
  def import_catalog(search_terms: nil)
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
      scraper = supplier.scraper_klass.new(credential)

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

  # Import a batch of scraped items into the DB immediately.
  # Called by the scraper via the block passed to scrape_catalog.
  def import_batch(items)
    items.each do |item|
      next if item[:supplier_sku].blank?
      next if @seen_skus.include?(item[:supplier_sku]) # Dedup within this import run

      @seen_skus.add(item[:supplier_sku])
      import_item(item, @existing_by_sku, @product_index)
      @items_processed += 1

      # Update progress every 25 items
      next unless (@items_processed % 25).zero?

      credential.update_columns(
        import_progress: @items_processed,
        import_total: @items_processed, # Best estimate — total unknown during streaming
        import_status_text: "Imported #{@items_processed} products so far..."
      )
      Rails.logger.info "[ImportProducts] #{supplier.name}: #{@items_processed} products processed (#{results[:imported]} new, #{results[:updated]} updated)"
    end
  end

  # Import a single scraped item into the database.
  # Uses pre-loaded data to avoid per-item DB queries.
  def import_item(item, existing_by_sku, product_index)
    return if item[:supplier_sku].blank? || item[:supplier_name].blank?

    # O(1) hash lookup instead of DB find_or_initialize_by
    supplier_product = existing_by_sku[item[:supplier_sku]]

    if supplier_product.nil?
      # New product — build in memory and save
      supplier_product = SupplierProduct.new(
        supplier: supplier,
        supplier_sku: item[:supplier_sku],
        supplier_name: item[:supplier_name],
        current_price: item[:current_price],
        pack_size: item[:pack_size],
        supplier_url: item[:supplier_url],
        in_stock: item[:in_stock] != false,
        price_updated_at: item[:current_price].present? ? Time.current : nil,
        last_scraped_at: Time.current
      )

      # Try to find or create a matching Product using in-memory index
      product = find_or_create_product(item, product_index)
      supplier_product.product = product if product

      if supplier_product.save
        # Add to the in-memory hash so subsequent duplicates in this batch
        # are caught without hitting the DB
        existing_by_sku[item[:supplier_sku]] = supplier_product
        results[:imported] += 1
      else
        results[:errors] << "#{item[:supplier_name]}: #{supplier_product.errors.full_messages.join(', ')}"
      end
    else
      # Update existing record with fresh data
      attrs = { last_scraped_at: Time.current, supplier_name: item[:supplier_name] }
      attrs[:pack_size] = item[:pack_size] if item[:pack_size].present?
      attrs[:supplier_url] = item[:supplier_url] if item[:supplier_url].present?

      if item[:current_price].present? && item[:current_price] != supplier_product.current_price
        attrs[:previous_price] = supplier_product.current_price
        attrs[:current_price] = item[:current_price]
        attrs[:price_updated_at] = Time.current
      end

      attrs[:in_stock] = item[:in_stock] unless item[:in_stock].nil?

      # Reset discontinuation tracking — product is still in the catalog
      if supplier_product.consecutive_misses > 0 || supplier_product.discontinued?
        attrs[:consecutive_misses] = 0
        if supplier_product.discontinued?
          attrs[:discontinued] = false
          attrs[:discontinued_at] = nil
          results[:reinstated] += 1
          Rails.logger.info "[ImportProducts] Reinstated #{item[:supplier_name]} (SKU: #{item[:supplier_sku]}) — reappeared in catalog"
        end
      end

      supplier_product.update!(attrs)
      results[:updated] += 1
    end
  rescue StandardError => e
    results[:errors] << "#{item[:supplier_name]}: #{e.message}"
    Rails.logger.warn "[ImportProducts] Error importing #{item[:supplier_sku]}: #{e.message}"
  end

  private

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

    if total_seen < MINIMUM_SCRAPE_THRESHOLD
      Rails.logger.info "[ImportProducts] Skipping miss tracking for #{supplier.name} — " \
                        "only #{total_seen} products seen (threshold: #{MINIMUM_SCRAPE_THRESHOLD})"
      return
    end

    unseen_skus = @existing_by_sku.keys - @seen_skus.to_a

    if unseen_skus.empty?
      Rails.logger.info "[ImportProducts] All #{@existing_by_sku.size} existing products were seen in scrape for #{supplier.name}"
      return
    end

    Rails.logger.info "[ImportProducts] #{supplier.name}: #{unseen_skus.size} existing products not seen in this scrape (#{total_seen} seen)"

    # Batch update for efficiency — increment consecutive_misses for all unseen products
    unseen_skus.each do |sku|
      product = @existing_by_sku[sku]
      next unless product

      product.record_miss!
      results[:discontinued] += 1 if product.discontinued?
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
