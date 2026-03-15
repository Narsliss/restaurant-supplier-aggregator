# Incrementally matches NEW supplier list items against EXISTING ProductMatches
# in an AggregatedList. This is the additive-only counterpart to AiProductMatcherService.
#
# CRITICAL GUARANTEE: This service NEVER modifies existing confirmed matches.
# It only creates new ProductMatchItems and new ProductMatch records.
#
# What is NEVER touched:
#   - Confirmed/manual/rejected match statuses
#   - Canonical names (including manual renames)
#   - Confidence scores on existing matches
#   - Positions of existing matches
#   - Existing supplier-to-match associations
#
# Usage:
#   service = IncrementalProductMatcherService.new(aggregated_list, [new_supplier_list_id])
#   result = service.call
#   # => { new_matched: 12, new_unmatched: 3, total_new: 15 }
#
class IncrementalProductMatcherService
  GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions'.freeze
  MODEL = 'llama-3.3-70b-versatile'.freeze
  SIMILARITY_THRESHOLD = 0.45
  AI_CONFIDENCE_THRESHOLD = 0.7

  attr_reader :aggregated_list, :new_supplier_list_ids, :results

  def initialize(aggregated_list, new_supplier_list_ids = [], items: nil)
    @aggregated_list = aggregated_list
    @new_supplier_list_ids = Array(new_supplier_list_ids).map(&:to_i)
    @explicit_items = items # pre-filtered items bypass collect_new_items
    @api_key = ENV['GROQ_API_KEY'] || Rails.application.credentials.dig(:groq, :api_key)
    @results = { new_matched: 0, new_unmatched: 0, total_new: 0, errors: [] }
    @ai_disabled = false
  end

  def call
    aggregated_list.mark_matching!

    # Load existing matches — these are READ-ONLY (we never modify them)
    existing_matches = load_existing_matches
    # Collect new items — use explicit items if provided, otherwise load from supplier lists
    new_items = @explicit_items || collect_new_items

    if new_items.empty?
      aggregated_list.mark_matched!
      return results
    end

    # Track which existing matches already have items from the new supplier(s)
    # to avoid creating duplicate ProductMatchItems
    existing_supplier_ids_by_match = build_existing_supplier_map(existing_matches)

    # Start positions after the last existing match
    next_position = (aggregated_list.product_matches.maximum(:position) || 0) + 1

    new_items.each do |new_item|
      supplier_id = new_item.supplier_list.supplier_id

      # Try to find a matching existing ProductMatch
      match, confidence = find_best_match_against_existing(new_item, existing_matches)

      if match
        # Check if this supplier already has an item in this match
        unless existing_supplier_ids_by_match[match.id]&.include?(supplier_id)
          # Create new ProductMatchItem linking new item to existing match
          match.product_match_items.create!(
            supplier_list_item: new_item,
            supplier_id: supplier_id,
            is_primary: false
          )

          # Track so we don't create duplicates for same supplier in same match
          existing_supplier_ids_by_match[match.id] ||= Set.new
          existing_supplier_ids_by_match[match.id] << supplier_id

          # If the existing match was 'unmatched' (only had one supplier),
          # upgrade it to 'auto_matched' since it now has cross-supplier data.
          # NEVER touch confirmed/manual/rejected statuses.
          if match.match_status == 'unmatched'
            match.update!(match_status: 'auto_matched')
          end
        end

        results[:new_matched] += 1
      else
        # No match found — create a new ProductMatch row
        new_match = aggregated_list.product_matches.create!(
          canonical_name: new_item.name.truncate(255),
          match_status: 'unmatched',
          confidence_score: 0.0,
          position: next_position
        )
        new_match.product_match_items.create!(
          supplier_list_item: new_item,
          supplier_id: supplier_id,
          is_primary: true
        )
        next_position += 1

        # Add to existing matches so subsequent new items can match against it
        existing_matches << new_match

        results[:new_unmatched] += 1
      end

      results[:total_new] += 1
    end

    aggregated_list.mark_matched!
    Rails.logger.info "[IncrementalMatcher] Complete: #{results}"
    results
  rescue StandardError => e
    Rails.logger.error "[IncrementalMatcher] Failed: #{e.class}: #{e.message}"
    # Only mark failed if there are no existing matches — don't clobber
    # a working list just because a re-match job errored
    if aggregated_list.product_matches.reload.any?
      Rails.logger.warn "[IncrementalMatcher] Keeping status — list has #{aggregated_list.product_matches.count} existing matches"
      aggregated_list.mark_matched! unless aggregated_list.matched?
    else
      aggregated_list.mark_failed!
    end
    results[:errors] << "#{e.class}: #{e.message}"
    results
  end

  private

  # Load all existing ProductMatches with their items preloaded for efficient matching
  def load_existing_matches
    aggregated_list.product_matches
                   .includes(product_match_items: { supplier_list_item: :supplier_product })
                   .order(:position)
                   .to_a
  end

  # Build a map of match_id => Set of supplier_ids that already have items
  def build_existing_supplier_map(existing_matches)
    map = {}
    existing_matches.each do |pm|
      map[pm.id] = Set.new(pm.product_match_items.map(&:supplier_id))
    end
    map
  end

  # Collect items from newly added supplier lists, deduplicating same-supplier items
  def collect_new_items
    new_lists = SupplierList.where(id: new_supplier_list_ids)
                            .includes(supplier_list_items: :supplier_product)

    items_by_supplier = {}
    new_lists.each do |sl|
      items_by_supplier[sl.supplier_id] ||= []
      items_by_supplier[sl.supplier_id].concat(sl.supplier_list_items.to_a)
    end

    # Deduplicate within each supplier by supplier_product_id (PRD 6.1.1)
    all_items = []
    items_by_supplier.each_value do |supplier_items|
      deduped = supplier_items
        .group_by { |item| item.supplier_product_id || item.id }
        .values
        .map { |dupes| dupes.max_by { |i| i.updated_at || Time.at(0) } }
      all_items.concat(deduped)
    end

    all_items
  end

  # Find the best matching existing ProductMatch for a new item.
  # Returns [product_match, confidence] or [nil, 0].
  def find_best_match_against_existing(new_item, existing_matches)
    return [nil, 0] if existing_matches.empty?

    new_name = new_item.name

    # Pass 1: Shared Product link
    if new_item.supplier_product&.product_id
      match = existing_matches.find do |pm|
        pm.product_match_items.any? do |pmi|
          pmi.supplier_list_item.supplier_product&.product_id == new_item.supplier_product.product_id
        end
      end
      return [match, 0.95] if match
    end

    # Pass 2: Exact normalized name match
    new_normalized = ProductNormalizer.normalize(new_name)
    if new_normalized.present?
      match = existing_matches.find do |pm|
        ProductNormalizer.normalize(pm.canonical_name || '') == new_normalized
      end
      return [match, 0.9] if match
    end

    # Pass 3: Best similarity score (Jaccard + containment)
    best_match = nil
    best_score = 0

    existing_matches.each do |pm|
      canonical = pm.canonical_name || pm.product_match_items.first&.name || ''
      score = ProductNormalizer.best_similarity(new_name, canonical)
      if score > best_score
        best_score = score
        best_match = pm
      end
    end

    return [best_match, best_score] if best_score >= SIMILARITY_THRESHOLD

    # Pass 4: AI matching via Groq
    return [nil, 0] unless @api_key.present? && !@ai_disabled

    ai_match = find_match_with_ai(new_item, existing_matches)
    ai_match || [nil, 0]
  end

  def find_match_with_ai(new_item, existing_matches)
    return nil if existing_matches.empty?

    # Pre-sort by similarity so most likely matches are sent to AI
    sorted_matches = existing_matches.sort_by do |pm|
      -ProductNormalizer.best_similarity(new_item.name, pm.canonical_name || '')
    end

    candidate_list = sorted_matches.first(15).map.with_index do |pm, i|
      name = pm.canonical_name || pm.product_match_items.first&.name || 'Unknown'
      "#{i + 1}. #{name}"
    end.join("\n")

    prompt = <<~PROMPT
      Is this restaurant supply product the same as any in the list below?
      Consider different brands, abbreviations, and pack sizes may refer to the same product.

      Product: "#{new_item.name}" (#{new_item.pack_size})

      Candidates:
      #{candidate_list}

      Reply with ONLY the number (1-#{[sorted_matches.size, 15].min}) of the matching product, or "NONE".
    PROMPT

    response = call_groq(prompt)
    return nil if response.blank? || response.upcase.include?('NONE')

    match_num = response.scan(/\d+/).first&.to_i
    return nil unless match_num&.between?(1, [sorted_matches.size, 15].min)

    [sorted_matches[match_num - 1], AI_CONFIDENCE_THRESHOLD]
  rescue StandardError => e
    Rails.logger.warn "[IncrementalMatcher] AI matching failed: #{e.message}"
    nil
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
      Rails.logger.warn "[IncrementalMatcher] Groq rate limited (429). Disabling AI matching for remainder of this run."
      @ai_disabled = true
      nil
    else
      Rails.logger.error "[IncrementalMatcher] Groq API error: #{response.status}"
      nil
    end
  rescue Faraday::Error => e
    Rails.logger.error "[IncrementalMatcher] Groq request failed: #{e.message}"
    nil
  end
end
