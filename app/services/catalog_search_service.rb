# Searches the full SupplierProduct catalog to find matches for unmatched
# items in an AggregatedList. When a match is found, creates a SupplierListItem
# from the SupplierProduct and links it into the existing ProductMatch row.
#
# Uses the same 4-pass matching strategy as AiProductMatcherService but
# searches against the full catalog (~19K products) instead of just order
# guide items. Uses a higher similarity threshold (0.55 vs 0.45) to reduce
# false positives against the larger candidate pool.
#
# Usage:
#   service = CatalogSearchService.new(aggregated_list)
#   result = service.call
#   # => { found: 12, searched: 256, created_sli_ids: [...], errors: [] }
#
class CatalogSearchService
  CATALOG_SIMILARITY_THRESHOLD = 0.55
  AI_CONFIDENCE_THRESHOLD = 0.7
  GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions'.freeze
  MODEL = 'llama-3.3-70b-versatile'.freeze

  attr_reader :aggregated_list, :results

  def initialize(aggregated_list)
    @aggregated_list = aggregated_list
    @api_key = ENV['GROQ_API_KEY'] || Rails.application.credentials.dig(:groq, :api_key)
    @results = { found: 0, searched: 0, created_sli_ids: [], errors: [] }
    @ai_disabled = false
  end

  def call
    unmatched = aggregated_list.product_matches.unmatched
                  .includes(product_match_items: [:supplier, { supplier_list_item: :supplier_product }])
    return results if unmatched.empty?

    # Build lookup: supplier_id -> SupplierList (mapped to this aggregated list)
    supplier_list_map = build_supplier_list_map
    all_supplier_ids = supplier_list_map.keys

    # Pre-normalize the full catalog once (the expensive part, ~2-5 seconds)
    Rails.logger.info "[CatalogSearch] Building catalog index for #{all_supplier_ids.size} suppliers..."
    catalog_index = build_catalog_index(all_supplier_ids)
    total_indexed = catalog_index.values.sum(&:size)
    Rails.logger.info "[CatalogSearch] Indexed #{total_indexed} catalog products. Searching #{unmatched.size} unmatched items..."

    unmatched.each do |product_match|
      results[:searched] += 1
      present_supplier_ids = product_match.product_match_items.map(&:supplier_id)
      missing_supplier_ids = all_supplier_ids - present_supplier_ids

      next if missing_supplier_ids.empty?

      # The existing item to use as anchor for searching
      anchor_item = product_match.product_match_items.first&.supplier_list_item
      next unless anchor_item

      found_any = false

      missing_supplier_ids.each do |supplier_id|
        supplier_list = supplier_list_map[supplier_id]
        next unless supplier_list

        catalog_entries = catalog_index[supplier_id] || []
        next if catalog_entries.empty?

        match_result = find_catalog_match(anchor_item, catalog_entries)
        next unless match_result

        matched_sp, confidence = match_result

        # Create a SupplierListItem from the SupplierProduct
        sli = create_supplier_list_item(supplier_list, matched_sp)
        next unless sli

        # Link it into the existing ProductMatch
        product_match.product_match_items.create!(
          supplier_list_item: sli,
          supplier_id: supplier_id,
          is_primary: false
        )

        results[:created_sli_ids] << sli.id
        found_any = true
      rescue ActiveRecord::RecordNotUnique => e
        # PMI already exists for this supplier on this match — skip
        Rails.logger.debug "[CatalogSearch] PMI already exists: #{e.message}"
      end

      if found_any
        product_match.update!(
          match_status: 'auto_matched',
          confidence_score: [product_match.confidence_score || 0, 0.5].max
        )
        results[:found] += 1
      end
    end

    # Refresh stored product counts on affected supplier lists so the
    # displayed counts include newly created catalog-search items.
    if results[:created_sli_ids].any?
      supplier_list_map.each_value(&:refresh_product_count!)
    end

    Rails.logger.info "[CatalogSearch] Complete: found #{results[:found]} new matches from #{results[:searched]} unmatched items"
    results
  rescue StandardError => e
    Rails.logger.error "[CatalogSearch] Failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    results[:errors] << "#{e.class}: #{e.message}"
    results
  end

  private

  # Map supplier_id -> SupplierList for this aggregated list
  def build_supplier_list_map
    map = {}
    aggregated_list.aggregated_list_mappings.includes(:supplier_list).each do |mapping|
      sl = mapping.supplier_list
      map[sl.supplier_id] = sl
    end
    map
  end

  # Pre-normalize all non-discontinued catalog products, grouped by supplier.
  # Returns: { supplier_id => [{ sp: SupplierProduct, normalized: "...", word_set: Set }] }
  def build_catalog_index(supplier_ids)
    index = {}
    supplier_ids.each do |sid|
      products = SupplierProduct.where(supplier_id: sid, discontinued: false)
                                .select(:id, :supplier_id, :supplier_sku, :supplier_name,
                                        :current_price, :pack_size, :in_stock, :product_id)
      entries = products.map do |sp|
        normalized = ProductNormalizer.normalize(sp.supplier_name)
        {
          sp: sp,
          normalized: normalized,
          word_set: normalized.downcase.split.to_set
        }
      end
      index[sid] = entries
    end
    index
  end

  # 4-pass matching against the catalog for a single anchor item.
  # Returns [SupplierProduct, confidence] or nil.
  def find_catalog_match(anchor_item, catalog_entries)
    anchor_normalized = ProductNormalizer.normalize(anchor_item.name)
    anchor_word_set = anchor_normalized.downcase.split.to_set

    return nil if anchor_word_set.empty?

    # Pass 1: Shared Product link
    if anchor_item.supplier_product&.product_id
      entry = catalog_entries.find { |e| e[:sp].product_id == anchor_item.supplier_product.product_id }
      return [entry[:sp], 0.95] if entry
    end

    # Pass 2: Exact normalized name match
    if anchor_normalized.present?
      entry = catalog_entries.find { |e| e[:normalized].present? && e[:normalized] == anchor_normalized }
      return [entry[:sp], 0.90] if entry
    end

    # Pass 3: Best similarity with word-set pre-filter
    best_entry = nil
    best_score = 0

    catalog_entries.each do |entry|
      # Quick pre-filter: skip if zero word overlap (eliminates ~95% of candidates)
      next if (anchor_word_set & entry[:word_set]).empty?

      score = ProductNormalizer.best_similarity(anchor_item.name, entry[:sp].supplier_name)
      if score > best_score
        best_score = score
        best_entry = entry
      end
    end

    return [best_entry[:sp], best_score] if best_entry && best_score >= CATALOG_SIMILARITY_THRESHOLD

    # Pass 4: AI matching (optional, only if API key present and not rate limited)
    return nil unless @api_key.present? && !@ai_disabled

    find_catalog_match_with_ai(anchor_item, catalog_entries)
  end

  def find_catalog_match_with_ai(anchor_item, catalog_entries)
    # Pre-sort by similarity, pick top 15 that have at least some overlap
    anchor_word_set = ProductNormalizer.normalize(anchor_item.name).downcase.split.to_set

    relevant = catalog_entries.select { |e| (anchor_word_set & e[:word_set]).any? }
    return nil if relevant.empty?

    sorted = relevant.sort_by do |entry|
      -ProductNormalizer.best_similarity(anchor_item.name, entry[:sp].supplier_name)
    end.first(15)

    # Only send to AI if the top candidate has at least some relevance
    top_score = ProductNormalizer.best_similarity(anchor_item.name, sorted.first[:sp].supplier_name)
    return nil if top_score < 0.25

    candidate_list = sorted.map.with_index do |entry, i|
      "#{i + 1}. #{entry[:sp].supplier_name} (#{entry[:sp].pack_size})"
    end.join("\n")

    prompt = <<~PROMPT
      Is this restaurant supply product the same as any in the list below?
      Consider different brands, abbreviations, and pack sizes may refer to the same product.

      Product: "#{anchor_item.name}" (#{anchor_item.pack_size})

      Candidates:
      #{candidate_list}

      Reply with ONLY the number (1-#{sorted.size}) of the matching product, or "NONE".
    PROMPT

    response = call_groq(prompt)
    return nil if response.blank? || response.upcase.include?('NONE')

    match_num = response.scan(/\d+/).first&.to_i
    return nil unless match_num&.between?(1, sorted.size)

    [sorted[match_num - 1][:sp], AI_CONFIDENCE_THRESHOLD]
  rescue StandardError => e
    Rails.logger.warn "[CatalogSearch] AI matching failed: #{e.message}"
    nil
  end

  # Create a SupplierListItem from a SupplierProduct on the given list.
  # Idempotent: returns existing SLI if one already exists for this SP/SKU.
  def create_supplier_list_item(supplier_list, supplier_product)
    # Check if SLI already exists for this SupplierProduct
    existing = supplier_list.supplier_list_items.find_by(supplier_product_id: supplier_product.id)
    return existing if existing

    # Check by SKU to avoid unique constraint violation
    if supplier_product.supplier_sku.present?
      existing_by_sku = supplier_list.supplier_list_items.find_by(sku: supplier_product.supplier_sku)
      return existing_by_sku if existing_by_sku
    end

    max_position = supplier_list.supplier_list_items.maximum(:position) || 0

    supplier_list.supplier_list_items.create!(
      name: supplier_product.supplier_name,
      sku: supplier_product.supplier_sku,
      price: supplier_product.current_price,
      pack_size: supplier_product.pack_size,
      in_stock: supplier_product.in_stock,
      supplier_product_id: supplier_product.id,
      position: max_position + 1,
      source: 'catalog_search'
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    Rails.logger.warn "[CatalogSearch] Failed to create SLI: #{e.message}"
    supplier_list.supplier_list_items.find_by(supplier_product_id: supplier_product.id)
  end

  def call_groq(prompt, max_tokens: 50)
    conn = Faraday.new(url: GROQ_API_URL, ssl: { verify: true }) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.open_timeout = 10
      f.options.timeout = 30
    end

    response = conn.post do |req|
      req.headers['Authorization'] = "Bearer #{@api_key}"
      req.headers['Content-Type'] = 'application/json'
      req.body = {
        model: MODEL,
        messages: [
          { role: 'system', content: 'You match restaurant supply products across different suppliers. Be concise.' },
          { role: 'user', content: prompt }
        ],
        max_tokens: max_tokens,
        temperature: 0.1
      }.to_json
    end

    if response.success?
      response.body.dig('choices', 0, 'message', 'content')
    elsif response.status == 429
      Rails.logger.warn "[CatalogSearch] Groq rate limited (429). Disabling AI matching for remainder of this run."
      @ai_disabled = true
      nil
    else
      Rails.logger.error "[CatalogSearch] Groq API error: #{response.status}"
      nil
    end
  rescue Faraday::Error => e
    Rails.logger.error "[CatalogSearch] Groq request failed: #{e.message}"
    nil
  end
end
