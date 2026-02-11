# Uses Groq's free API (Llama 3) to intelligently group similar products
# across suppliers by understanding product semantics.
#
# Groq free tier: https://console.groq.com/
# - 14,400 requests/day
# - 30 requests/minute
#
# Set GROQ_API_KEY in your environment or credentials.
class AiProductGrouper
  GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions".freeze
  MODEL = "llama-3.3-70b-versatile".freeze  # Fast and capable

  attr_reader :results

  def initialize
    @api_key = ENV["GROQ_API_KEY"] || Rails.application.credentials.dig(:groq, :api_key)
    @results = { matched: 0, created: 0, skipped: 0, errors: [] }
  end

  # Find unlinked supplier products and try to match them to existing products
  def group_unlinked_products(limit: 100)
    unless @api_key.present?
      @results[:errors] << "GROQ_API_KEY not configured"
      return @results
    end

    # Find supplier products without a product link
    unlinked = SupplierProduct.where(product_id: nil).limit(limit)
    Rails.logger.info "[AiGrouper] Found #{unlinked.count} unlinked supplier products"

    unlinked.each do |sp|
      process_supplier_product(sp)
      sleep 0.1  # Rate limiting (30 req/min = ~2 req/sec max)
    end

    @results
  end

  # Find potential duplicates among existing products and suggest merges
  # Uses rule-based similarity to find candidates, then AI to validate
  def find_duplicate_products(limit: 50)
    unless @api_key.present?
      @results[:errors] << "GROQ_API_KEY not configured"
      return []
    end

    # First, find candidates using rule-based similarity
    candidates = find_duplicate_candidates
    Rails.logger.info "[AiGrouper] Found #{candidates.size} candidate duplicate pairs"

    # Then validate with AI
    validated = []
    candidates.first(limit * 2).each do |candidate|
      break if validated.size >= limit

      if validate_duplicate_with_ai(candidate[:product1], candidate[:product2])
        validated << candidate
        print "."
      end
      sleep 0.1  # Rate limiting
    end
    puts "" if validated.any?

    validated
  end

  # Merge duplicate products - moves all supplier products to the primary and deletes the duplicate
  def merge_products(primary_id, duplicate_id)
    primary = Product.find(primary_id)
    duplicate = Product.find(duplicate_id)

    ActiveRecord::Base.transaction do
      # Move supplier products to primary
      duplicate.supplier_products.update_all(product_id: primary.id)

      # Delete the duplicate
      duplicate.destroy!
    end

    Rails.logger.info "[AiGrouper] Merged '#{duplicate.name}' into '#{primary.name}'"
    true
  rescue => e
    Rails.logger.error "[AiGrouper] Failed to merge #{duplicate_id} into #{primary_id}: #{e.message}"
    false
  end

  # Use AI to suggest a canonical name for a product
  def suggest_canonical_name(product_names)
    return nil unless @api_key.present?

    prompt = <<~PROMPT
      Given these product names from different suppliers, suggest ONE canonical/standardized product name.
      The name should be generic enough to match across suppliers but specific enough to identify the product.
      Remove brand names, pack sizes, and supplier-specific codes.
      Return ONLY the canonical name, nothing else.

      Product names:
      #{product_names.map { |n| "- #{n}" }.join("\n")}
    PROMPT

    response = call_groq(prompt)
    response&.strip
  end

  private

  def process_supplier_product(sp)
    # First, try to find existing products that might match
    candidates = find_candidate_products(sp.supplier_name)

    if candidates.any?
      # Use AI to determine if any candidate is a match
      match = find_best_match_with_ai(sp.supplier_name, candidates)

      if match
        sp.update!(product_id: match.id)
        @results[:matched] += 1
        Rails.logger.info "[AiGrouper] Matched '#{sp.supplier_name}' to '#{match.name}'"
        return
      end
    end

    # No match found - create a new product with AI-suggested canonical name
    canonical = suggest_canonical_name([sp.supplier_name])
    if canonical.present?
      product = Product.create!(
        name: canonical.split.map(&:capitalize).join(" "),
        normalized_name: canonical.downcase.gsub(/[^a-z0-9\s]/, "").squish,
        category: guess_category_with_ai(sp.supplier_name)
      )
      sp.update!(product_id: product.id)
      @results[:created] += 1
      Rails.logger.info "[AiGrouper] Created new product '#{product.name}' for '#{sp.supplier_name}'"
    else
      @results[:skipped] += 1
    end
  rescue => e
    @results[:errors] << "#{sp.supplier_name}: #{e.message}"
    Rails.logger.warn "[AiGrouper] Error processing #{sp.id}: #{e.message}"
  end

  def find_candidate_products(supplier_name)
    # Use existing normalizer to get candidate matches
    normalizer = ProductNormalizer.new(supplier_name)
    canonical = normalizer.canonical_name
    return [] if canonical.blank?

    # Find products with similar normalized names
    first_word = canonical.split.first
    return [] if first_word.blank?

    Product.where("normalized_name LIKE ?", "#{first_word}%")
      .or(Product.where("name LIKE ?", "%#{first_word}%"))
      .limit(20)
      .to_a
  end

  def find_best_match_with_ai(supplier_name, candidates)
    return nil if candidates.empty?

    candidate_list = candidates.map.with_index { |c, i| "#{i + 1}. #{c.name}" }.join("\n")

    prompt = <<~PROMPT
      Is the supplier product "#{supplier_name}" the same as any of these products?
      Consider that products may have different brands, sizes, or packaging but be essentially the same item.

      Candidates:
      #{candidate_list}

      Reply with ONLY the number of the matching product (1-#{candidates.size}), or "NONE" if none match.
      Be strict - only match if it's clearly the same product type.
    PROMPT

    response = call_groq(prompt)
    return nil if response.blank? || response.upcase.include?("NONE")

    # Extract number from response
    match_num = response.scan(/\d+/).first&.to_i
    return nil unless match_num && match_num.between?(1, candidates.size)

    candidates[match_num - 1]
  end

  # Find duplicate candidates using rule-based similarity (like the rake task)
  def find_duplicate_candidates
    checked = Set.new
    candidates = []

    Product.find_each do |product|
      next if checked.include?(product.id)

      normalizer = ProductNormalizer.new(product.name)
      base = normalizer.base_name
      next if base.blank? || base.split.size < 2

      first_word = base.split.first
      similar_products = Product
        .where.not(id: product.id)
        .where("normalized_name LIKE ?", "%#{first_word}%")
        .to_a

      similar_products.each do |candidate|
        next if checked.include?(candidate.id)

        score = ProductNormalizer.similarity(product.name, candidate.name)
        if score >= 0.65 && score < 1.0
          candidates << {
            product1: product,
            product2: candidate,
            score: score
          }
          checked << candidate.id
        end
      end

      checked << product.id
    end

    # Sort by score descending
    candidates.sort_by { |c| -c[:score] }
  end

  # Use AI to validate if two products are really duplicates
  def validate_duplicate_with_ai(product1, product2)
    prompt = <<~PROMPT
      Are these two restaurant supply products the SAME product that should be merged?
      Consider: they might have different brands, sizes, or wording but be the same core product.

      Product 1: #{product1.name}
      Product 2: #{product2.name}

      Reply with ONLY "YES" if they are the same product and should be merged, or "NO" if they are different products.
    PROMPT

    response = call_groq(prompt, max_tokens: 10)
    response&.strip&.upcase&.start_with?("YES")
  end

  def find_similar_pairs_with_ai(product_names)
    return [] if product_names.size < 2

    name_list = product_names.map { |p| "#{p[:id]}: #{p[:name]}" }.join("\n")

    prompt = <<~PROMPT
      Look at these product names and identify any pairs that are likely duplicates (same product, different naming).
      Consider different spellings, abbreviations, brand variations, etc.

      Products:
      #{name_list}

      Reply with pairs of IDs that should be merged, one pair per line in format "ID1,ID2".
      If no duplicates, reply "NONE".
    PROMPT

    response = call_groq(prompt)
    return [] if response.blank? || response.upcase.include?("NONE")

    # Parse pairs from response
    pairs = []
    response.scan(/(\d+)\s*,\s*(\d+)/).each do |id1, id2|
      p1 = product_names.find { |p| p[:id].to_s == id1 }
      p2 = product_names.find { |p| p[:id].to_s == id2 }
      pairs << [p1, p2] if p1 && p2
    end

    pairs
  end

  def guess_category_with_ai(product_name)
    categories = Product.distinct.pluck(:category).compact.sort

    prompt = <<~PROMPT
      What category does this food product belong to?
      Product: #{product_name}

      Choose from: #{categories.join(", ")}

      Reply with ONLY the category name, nothing else.
    PROMPT

    response = call_groq(prompt)
    category = response&.strip

    # Validate it's one of our categories
    categories.include?(category) ? category : nil
  end

  def call_groq(prompt, max_tokens: 100)
    conn = Faraday.new(url: GROQ_API_URL, ssl: { verify: true, ca_file: nil }) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.open_timeout = 10
      f.options.timeout = 30
    end

    response = conn.post do |req|
      req.headers["Authorization"] = "Bearer #{@api_key}"
      req.headers["Content-Type"] = "application/json"
      req.body = {
        model: MODEL,
        messages: [
          { role: "system", content: "You are a helpful assistant that categorizes and matches food products for a restaurant supply platform. Be concise and precise." },
          { role: "user", content: prompt }
        ],
        max_tokens: max_tokens,
        temperature: 0.1  # Low temperature for consistent responses
      }.to_json
    end

    if response.success?
      response.body.dig("choices", 0, "message", "content")
    else
      Rails.logger.error "[AiGrouper] Groq API error: #{response.status} - #{response.body}"
      nil
    end
  rescue Faraday::Error => e
    Rails.logger.error "[AiGrouper] Groq API request failed: #{e.message}"
    nil
  end
end
