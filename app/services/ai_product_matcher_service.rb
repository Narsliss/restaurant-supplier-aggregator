# Matches products across supplier lists within an AggregatedList.
# Uses a multi-pass strategy:
#   Pass 1: Shared Product link (both items link to same canonical Product)
#   Pass 2: Exact normalized name match via ProductNormalizer
#   Pass 3: Jaccard similarity >= 0.6 (lower for cross-supplier matching)
#   Pass 4: AI matching via Groq for remaining unmatched items
#
# Usage:
#   service = AiProductMatcherService.new(aggregated_list)
#   result = service.call
#   # => { matched: 45, unmatched: 8, total: 53 }
#
class AiProductMatcherService
  GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions'.freeze
  MODEL = 'llama-3.3-70b-versatile'.freeze
  SIMILARITY_THRESHOLD = 0.6
  AI_CONFIDENCE_THRESHOLD = 0.7
  BATCH_SIZE = 10

  attr_reader :aggregated_list, :results

  def initialize(aggregated_list)
    @aggregated_list = aggregated_list
    @api_key = ENV['GROQ_API_KEY'] || Rails.application.credentials.dig(:groq, :api_key)
    @results = { matched: 0, unmatched: 0, total: 0, errors: [] }
  end

  def call
    aggregated_list.mark_matching!

    # Clear existing matches (re-running matching)
    aggregated_list.product_matches.destroy_all

    # Collect all items from connected supplier lists, grouped by supplier
    items_by_supplier = collect_items_by_supplier
    return finish_empty if items_by_supplier.size < 2

    # Pick anchor list (most items)
    anchor_supplier_id, anchor_items = items_by_supplier.max_by { |_, items| items.size }
    other_suppliers = items_by_supplier.except(anchor_supplier_id)

    Rails.logger.info "[AiMatcher] Anchor: supplier #{anchor_supplier_id} with #{anchor_items.size} items. " \
                      "Matching against #{other_suppliers.size} other suppliers."

    position = 0

    # For each anchor item, try to find matches in other suppliers
    anchor_items.each do |anchor_item|
      position += 1
      matched_items = { anchor_supplier_id => anchor_item }
      best_confidence = 1.0 # Anchor is always 100% confident

      other_suppliers.each do |supplier_id, supplier_items|
        match, confidence = find_best_match(anchor_item, supplier_items)
        next unless match

        matched_items[supplier_id] = match
        best_confidence = [best_confidence, confidence].min
        # Remove matched item from pool so it can't match again
        supplier_items.delete(match)
      end

      # Create ProductMatch record
      match_status = if matched_items.size > 1
                       best_confidence >= AI_CONFIDENCE_THRESHOLD ? 'auto_matched' : 'auto_matched'
                     else
                       'unmatched'
                     end

      canonical = suggest_canonical_name(matched_items.values) || anchor_item.name

      product_match = aggregated_list.product_matches.create!(
        canonical_name: canonical.truncate(255),
        match_status: match_status,
        confidence_score: best_confidence.round(2),
        position: position
      )

      # Create ProductMatchItem for each supplier's matched item
      matched_items.each do |supplier_id, item|
        product_match.product_match_items.create!(
          supplier_list_item: item,
          supplier_id: item.supplier_list.supplier_id,
          is_primary: supplier_id == anchor_supplier_id
        )
      end

      if matched_items.size > 1
        results[:matched] += 1
      else
        results[:unmatched] += 1
      end
      results[:total] += 1
    end

    # Handle leftover items in non-anchor lists (no anchor match found)
    other_suppliers.each do |_supplier_id, remaining_items|
      remaining_items.each do |item|
        position += 1
        product_match = aggregated_list.product_matches.create!(
          canonical_name: item.name.truncate(255),
          match_status: 'unmatched',
          confidence_score: 0.0,
          position: position
        )
        product_match.product_match_items.create!(
          supplier_list_item: item,
          supplier_id: item.supplier_list.supplier_id,
          is_primary: true
        )
        results[:unmatched] += 1
        results[:total] += 1
      end
    end

    aggregated_list.mark_matched!
    Rails.logger.info "[AiMatcher] Complete: #{results}"
    results
  rescue StandardError => e
    Rails.logger.error "[AiMatcher] Failed: #{e.class}: #{e.message}"
    aggregated_list.mark_failed!
    results[:errors] << "#{e.class}: #{e.message}"
    results
  end

  private

  def collect_items_by_supplier
    items = {}
    aggregated_list.supplier_lists.includes(:supplier_list_items).each do |sl|
      items[sl.supplier_id] = sl.supplier_list_items.by_position.to_a
    end
    items
  end

  def finish_empty
    aggregated_list.mark_matched!
    results
  end

  # Find the best matching item from candidates for the given anchor item.
  # Returns [item, confidence] or [nil, 0].
  def find_best_match(anchor_item, candidates)
    return [nil, 0] if candidates.empty?

    # Pass 1: Shared Product link
    if anchor_item.supplier_product&.product_id
      match = candidates.find do |c|
        c.supplier_product&.product_id == anchor_item.supplier_product.product_id
      end
      return [match, 0.95] if match
    end

    # Pass 2: Exact normalized name match
    anchor_normalized = ProductNormalizer.normalize(anchor_item.name)
    candidates.each do |candidate|
      candidate_normalized = ProductNormalizer.normalize(candidate.name)
      return [candidate, 0.9] if anchor_normalized.present? && anchor_normalized == candidate_normalized
    end

    # Pass 3: Jaccard similarity
    best_candidate = nil
    best_score = 0

    candidates.each do |candidate|
      score = ProductNormalizer.similarity(anchor_item.name, candidate.name)
      if score > best_score
        best_score = score
        best_candidate = candidate
      end
    end

    return [best_candidate, best_score] if best_score >= SIMILARITY_THRESHOLD

    # Pass 4: AI matching (for remaining difficult cases)
    return [nil, 0] unless @api_key.present?

    ai_match = find_match_with_ai(anchor_item, candidates)
    ai_match || [nil, 0]
  end

  def find_match_with_ai(anchor_item, candidates)
    return nil if candidates.empty? || candidates.size > 20

    candidate_list = candidates.first(15).map.with_index do |c, i|
      "#{i + 1}. #{c.name} (#{c.pack_size})"
    end.join("\n")

    prompt = <<~PROMPT
      Is this restaurant supply product the same as any in the list below?
      Consider different brands, abbreviations, and pack sizes may refer to the same product.

      Product: "#{anchor_item.name}" (#{anchor_item.pack_size})

      Candidates:
      #{candidate_list}

      Reply with ONLY the number (1-#{[candidates.size, 15].min}) of the matching product, or "NONE".
    PROMPT

    response = call_groq(prompt)
    return nil if response.blank? || response.upcase.include?('NONE')

    match_num = response.scan(/\d+/).first&.to_i
    return nil unless match_num&.between?(1, [candidates.size, 15].min)

    [candidates[match_num - 1], AI_CONFIDENCE_THRESHOLD]
  rescue StandardError => e
    Rails.logger.warn "[AiMatcher] AI matching failed: #{e.message}"
    nil
  end

  def suggest_canonical_name(items)
    return items.first&.name if items.size <= 1

    names = items.map(&:name)
    # Use the shortest non-abbreviated name as a starting point
    normalizer = ProductNormalizer.new(names.min_by(&:length))
    canonical = normalizer.canonical_name
    return canonical.split.map(&:capitalize).join(' ') if canonical.present?

    names.first
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
    else
      Rails.logger.error "[AiMatcher] Groq API error: #{response.status}"
      nil
    end
  rescue Faraday::Error => e
    Rails.logger.error "[AiMatcher] Groq request failed: #{e.message}"
    nil
  end
end
