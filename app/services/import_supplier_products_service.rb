class ImportSupplierProductsService
  attr_reader :supplier, :credential, :results

  def initialize(credential)
    @credential = credential
    @supplier = credential.supplier
    @results = { imported: 0, updated: 0, skipped: 0, errors: [] }
  end

  # Import products from the supplier's catalog by searching for common food categories
  def import_catalog(search_terms: nil)
    search_terms ||= default_search_terms

    Rails.logger.info "[ImportProducts] Starting catalog import for #{supplier.name} with #{search_terms.size} search terms"

    # Phase 1: Scraping — report status so the UI shows activity
    credential.update_columns(import_status_text: "Searching #{supplier.name} catalog...")

    begin
      scraper = supplier.scraper_klass.new(credential)
      catalog_items = scraper.scrape_catalog(search_terms)
    rescue Scrapers::BaseScraper::AuthenticationError => e
      credential.mark_failed!(e.message)
      results[:errors] << "Authentication failed: #{e.message}"
      return results
    rescue => e
      results[:errors] << "Scraping failed: #{e.class.name} — #{e.message}"
      Rails.logger.error "[ImportProducts] Scraping failed for #{supplier.name}: #{e.message}"
      return results
    end

    Rails.logger.info "[ImportProducts] Found #{catalog_items.size} items from #{supplier.name}"

    # Phase 2: DB processing — pre-load data and report progress
    credential.update_columns(
      import_total: catalog_items.size,
      import_progress: 0,
      import_status_text: "Processing products..."
    )

    # Pre-load all existing supplier products for this supplier in one query.
    # This eliminates per-item find_or_initialize_by (N DB roundtrips → 1).
    existing_by_sku = SupplierProduct
      .where(supplier: supplier)
      .index_by(&:supplier_sku)

    # Pre-load all products for matching (eliminates per-item LIKE queries).
    # Build an in-memory index keyed by first word of normalized_name for fast lookup.
    all_products = Product.select(:id, :name, :normalized_name).to_a
    product_index = build_product_index(all_products)

    catalog_items.each_with_index do |item, idx|
      import_item(item, existing_by_sku, product_index)

      # Update progress every 10 items (avoid hammering DB on every single item)
      if (idx + 1) % 10 == 0 || idx == catalog_items.size - 1
        credential.update_columns(
          import_progress: idx + 1,
          import_status_text: "Processing #{idx + 1} of #{catalog_items.size} products..."
        )
      end
    end

    Rails.logger.info "[ImportProducts] #{supplier.name} import complete: #{results[:imported]} imported, #{results[:updated]} updated, #{results[:skipped]} skipped"
    results
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

      if item[:in_stock] != nil
        attrs[:in_stock] = item[:in_stock]
      end

      supplier_product.update!(attrs)
      results[:updated] += 1
    end
  rescue => e
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
        if word != first_word && word.include?(first_word)
          all_candidates.concat(products)
        end
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
    end

    # No match found - create a new canonical product
    display_name = canonical.split.map(&:capitalize).join(" ")
    categorization = AiProductCategorizer.rule_based_categorize(item[:supplier_name])

    new_product = Product.create!(
      name: display_name,
      normalized_name: canonical.downcase.gsub(/[^a-z0-9\s]/, "").squish,
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

  # Use AI-powered categorizer for better accuracy
  def guess_category(name)
    result = AiProductCategorizer.rule_based_categorize(name)
    result[:category]
  end

  def guess_subcategory(name)
    result = AiProductCategorizer.rule_based_categorize(name)
    result[:subcategory]
  end

  def default_search_terms
    # Consolidated from 63 to 35 terms — removed overlapping terms that
    # return duplicate products (e.g. "cream" covers "sour cream"/"ice cream",
    # "frozen" overlaps with specific proteins/vegetables).
    # Each term is chosen to maximize unique product coverage.
    %w[
      chicken beef pork salmon shrimp
      lettuce tomato onion potato
      cheese butter cream milk
      oil flour sugar rice pasta
      turkey bacon sausage
      lobster tilapia tuna
      mushroom pepper garlic
      broccoli squash avocado
      bread tortilla
      sauce vinegar
      coffee juice
      egg yogurt frozen
      seasoning
    ]
  end
end
