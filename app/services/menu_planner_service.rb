# Orchestrates AI menu generation for event plans.
#
# Flow:
#   1. Build conversation history from EventPlanMessages
#   2. Call Groq (Llama 3.3-70b) with system prompt + conversation (JSON output)
#   3. Parse response — extract event details, courses, ingredients
#   4. Search supplier catalog for each ingredient
#   5. Calculate costs against budget
#   6. Return formatted content + structured data
#
# Usage:
#   result = MenuPlannerService.new(event_plan: plan, user_message: "Wine dinner...").call
#   # => { display_content: "...", structured_data: { courses: [...], cost_summary: {...} } }
#
class MenuPlannerService
  GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions".freeze
  MENU_MODEL = "llama-3.3-70b-versatile".freeze
  MAX_CONVERSATION_MESSAGES = 20
  INGREDIENT_SIMILARITY_THRESHOLD = 0.40

  def initialize(event_plan:, user_message:)
    @event_plan = event_plan
    @user_message = user_message
    @organization = event_plan.organization
    @api_key = ENV["GROQ_API_KEY"] || Rails.application.credentials.dig(:groq, :api_key)
  end

  def call
    # 1. Call Groq
    ai_response = call_groq
    return error_result("No response from AI") unless ai_response

    # 2. Parse JSON response
    parsed = parse_response(ai_response)
    return error_result("Could not parse menu response") unless parsed

    # 3. Update event details if extracted
    update_event_details(parsed["event_details"]) if parsed["event_details"]

    # 4. If we have courses with ingredients, search catalog and calculate costs
    if parsed["courses"]&.any?
      search_catalog_for_ingredients(parsed["courses"])
      calculate_costs(parsed)
      @event_plan.update!(current_menu: parsed)
    end

    # 5. Build display content
    display = parsed["summary"] || build_display_summary(parsed)

    {
      display_content: display,
      structured_data: parsed
    }
  rescue Faraday::Error => e
    Rails.logger.error "[MenuPlanner] Groq API error: #{e.message}"
    error_result("AI service error: #{e.message}")
  rescue => e
    Rails.logger.error "[MenuPlanner] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    error_result("Something went wrong generating the menu. Please try again.")
  end

  private

  def call_groq
    messages = build_conversation_messages

    Rails.logger.info "[MenuPlanner] Calling Groq #{MENU_MODEL} with #{messages.size} messages"

    conn = Faraday.new(url: GROQ_API_URL, ssl: { verify: true }) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.open_timeout = 15
      f.options.timeout = 60
    end

    response = conn.post do |req|
      req.headers["Authorization"] = "Bearer #{@api_key}"
      req.headers["Content-Type"] = "application/json"
      req.body = {
        model: MENU_MODEL,
        messages: messages,
        response_format: { type: "json_object" },
        temperature: 0.7,
        max_tokens: 4096
      }.to_json
    end

    if response.success?
      content = response.body.dig("choices", 0, "message", "content")
      Rails.logger.info "[MenuPlanner] Got response (#{content&.length || 0} chars)"
      content
    elsif response.status == 429
      Rails.logger.warn "[MenuPlanner] Groq rate limited (429)"
      nil
    else
      Rails.logger.error "[MenuPlanner] Groq API error: #{response.status} — #{response.body}"
      nil
    end
  end

  def build_conversation_messages
    messages = [{ role: "system", content: system_prompt }]

    # Add conversation history (limited to recent messages)
    @event_plan.conversation_messages
      .where(status: "complete")
      .last(MAX_CONVERSATION_MESSAGES)
      .each do |msg|
        messages << { role: msg.role, content: msg.content }
      end

    # Add current user message
    messages << { role: "user", content: @user_message }

    messages
  end

  def system_prompt
    supplier_names = @organization.supplier_credentials
      .joins(:supplier)
      .where(status: "active")
      .pluck("suppliers.name")
      .uniq

    cuisine_style = @event_plan.event_details["cuisine_style"]
    cuisine_context = if cuisine_style.present?
      "\n      This restaurant's cuisine style is: #{cuisine_style}. ALL dishes must be consistent with this culinary identity. Do NOT suggest dishes from unrelated cuisines (e.g., no Asian dishes for an Italian restaurant). Adapt wine pairings to complement the restaurant's style.\n"
    else
      ""
    end

    <<~PROMPT
      You are an expert executive chef and sommelier helping plan event menus for a restaurant.
      You have deep knowledge of wine, food pairing, and professional kitchen operations.

      The restaurant orders from these suppliers: #{supplier_names.join(", ")}.
      #{cuisine_context}
      When a user describes an event, you must respond with valid JSON in this exact structure:

      {
        "summary": "A brief conversational message about the menu you've created (2-3 sentences).",
        "event_details": {
          "event_type": "Wine Dinner",
          "date": "2026-03-08",
          "covers": 50,
          "budget_per_cover": 100,
          "cuisine_style": "Argentinian / Italian",
          "wines": ["2020 Chablis Premier Cru", "Sancerre Rosé"]
        },
        "courses": [
          {
            "number": 1,
            "name": "Amuse-Bouche",
            "dish_name": "Seared Diver Scallop with Meyer Lemon Beurre Blanc",
            "description": "A delicate opener showcasing sweet scallop against bright citrus and rich butter.",
            "wine": {
              "name": "2020 Chablis Premier Cru",
              "tasting_notes": "Crisp minerality, green apple, white flower aromatics with a flinty finish.",
              "pairing_rationale": "The Chablis' bright acidity and minerality cuts through the butter sauce while complementing the scallop's natural sweetness."
            },
            "ingredients": [
              { "name": "dry sea scallops U-10", "quantity": 55, "unit": "each", "category": "Seafood" },
              { "name": "unsalted butter", "quantity": 3, "unit": "lb", "category": "Dairy" },
              { "name": "Meyer lemons", "quantity": 12, "unit": "each", "category": "Produce" },
              { "name": "shallots", "quantity": 1, "unit": "lb", "category": "Produce" },
              { "name": "dry white wine", "quantity": 1, "unit": "bottle", "category": "Beverages" },
              { "name": "chives", "quantity": 2, "unit": "bunch", "category": "Produce" },
              { "name": "kosher salt", "quantity": 0.5, "unit": "lb", "category": "Spices" },
              { "name": "black pepper", "quantity": 0.25, "unit": "lb", "category": "Spices" },
              { "name": "olive oil", "quantity": 0.5, "unit": "qt", "category": "Oils & Condiments" }
            ]
          }
        ]
      }

      IMPORTANT RULES:
      - Generate one course per wine. If fewer wines than courses make sense, you may add an amuse-bouche or intermezzo without a wine pairing.
      - Scale ALL ingredient quantities to the specified cover count. Add 10% buffer for kitchen waste.
      - Use standard restaurant purchasing units: lb, oz, each, bunch, qt, gal, case, bag, can, bottle.
      - Use ingredient names that would match real supplier catalog items (e.g., "chicken breast boneless skinless" not "chicken breast").
      - Keep food costs within the budget per cover. If over budget, suggest more affordable alternatives.
      - For refinement requests (swaps, substitutions, budget adjustments), update only the affected courses and return the full menu structure.
      - If the user asks a question (not requesting a menu), set "courses" to null and put your answer in "summary".
      - event_details should only be set on the initial request or if the user changes parameters. Set to null on refinements.
      - Wine tasting notes should cover: appearance, aroma, palate, and finish.
      - Pairing rationale should reference specific flavor interactions (acid/fat, tannin/protein, sweet/salt, etc.).
      - If the user specifies a cuisine style (e.g., "Argentinian / Italian", "French bistro", "Modern American"), ALL dishes MUST be authentic to or inspired by that cuisine. Never generate dishes from unrelated culinary traditions.
      - If no cuisine_style is specified but the user mentions their restaurant type, extract it into event_details.cuisine_style.
    PROMPT
  end

  def parse_response(content)
    JSON.parse(content)
  rescue JSON::ParserError => e
    Rails.logger.error "[MenuPlanner] JSON parse error: #{e.message}"
    nil
  end

  def update_event_details(details)
    return unless details.is_a?(Hash)

    merged = @event_plan.event_details.merge(details.compact)
    @event_plan.update!(event_details: merged)
    @event_plan.auto_title!
  end

  # --- Catalog Search ---

  def search_catalog_for_ingredients(courses)
    # Get all supplier products available to this org
    supplier_ids = @organization.supplier_credentials
      .where(status: "active")
      .pluck(:supplier_id)
      .uniq

    return if supplier_ids.empty?

    # Build a simple normalized index: { normalized_name => [supplier_product, ...] }
    catalog = SupplierProduct
      .where(supplier_id: supplier_ids, discontinued: false)
      .where.not(current_price: nil)
      .includes(:supplier, :product)
      .index_by_normalized_name

    Rails.logger.info "[MenuPlanner] Searching #{catalog.size} catalog entries for ingredients"

    courses.each do |course|
      next unless course["ingredients"]

      course["ingredients"].each do |ingredient|
        match = find_best_catalog_match(ingredient["name"], catalog)
        if match
          sp = match[:supplier_product]
          ingredient["matched_product"] = {
            "supplier_product_id" => sp.id,
            "supplier_name" => sp.supplier.name,
            "product_name" => sp.supplier_name || sp.product&.name,
            "pack_size" => sp.pack_size,
            "unit_price" => sp.current_price.to_f
          }
          ingredient["estimated_cost"] = estimate_ingredient_cost(ingredient, sp)
        else
          # AI-estimated cost placeholder (rough estimate for unmatched)
          ingredient["estimated_cost"] = estimate_unmatched_cost(ingredient)
        end
      end
    end
  end

  def find_best_catalog_match(ingredient_name, catalog)
    normalized = ProductNormalizer.normalize(ingredient_name)
    best_match = nil
    best_score = 0

    catalog.each do |cat_name, products|
      score = ProductNormalizer.best_similarity(normalized, cat_name)
      if score > best_score && score >= INGREDIENT_SIMILARITY_THRESHOLD
        best_score = score
        best_match = { supplier_product: cheapest_in_stock(products), score: score }
      end
    end

    best_match
  end

  def cheapest_in_stock(products)
    products
      .select { |sp| sp.in_stock? && sp.current_price.present? }
      .min_by(&:current_price) || products.first
  end

  def estimate_ingredient_cost(ingredient, supplier_product)
    # Simple estimate: if the ingredient quantity fits within one pack, use pack price
    # Otherwise multiply. This is rough — real ordering uses the order builder for precision.
    price = supplier_product.current_price.to_f
    qty = ingredient["quantity"].to_f

    # If the supplier product has a per-unit price, use it
    if supplier_product.respond_to?(:per_unit_price) && supplier_product.per_unit_price
      return (supplier_product.per_unit_price * qty).round(2)
    end

    # Fallback: assume 1 pack covers the quantity (very rough)
    price.round(2)
  end

  def estimate_unmatched_cost(ingredient)
    # Very rough estimates by category for unmatched ingredients
    estimates = {
      "Seafood" => 15.0, "Meat" => 12.0, "Poultry" => 8.0,
      "Produce" => 3.0, "Dairy" => 5.0, "Spices" => 2.0,
      "Oils & Condiments" => 4.0, "Dry Goods" => 3.0,
      "Beverages" => 8.0, "Bakery" => 4.0
    }
    per_unit = estimates[ingredient["category"]] || 5.0
    (per_unit * (ingredient["quantity"] || 1).to_f * 0.5).round(2)
  end

  # --- Cost Calculation ---

  def calculate_costs(parsed)
    courses = parsed["courses"] || []
    total_cost = 0
    matched_count = 0
    total_ingredients = 0

    courses.each do |course|
      course_cost = 0
      (course["ingredients"] || []).each do |ing|
        total_ingredients += 1
        matched_count += 1 if ing["matched_product"]
        course_cost += (ing["estimated_cost"] || 0).to_f
      end
      course["course_cost"] = course_cost.round(2)
      total_cost += course_cost
    end

    covers = @event_plan.covers || 1
    budget = @event_plan.budget_per_cover

    parsed["cost_summary"] = {
      "total_cost" => total_cost.round(2),
      "cost_per_cover" => (total_cost / covers).round(2),
      "budget_per_cover" => budget,
      "matched_count" => matched_count,
      "total_ingredients" => total_ingredients,
      "match_rate" => total_ingredients > 0 ? (matched_count * 100.0 / total_ingredients).round(0) : 0
    }
  end

  # --- Helpers ---

  def build_display_summary(parsed)
    parts = []
    if parsed["summary"]
      parts << parsed["summary"]
    end

    if parsed["courses"]&.any?
      parts << "Here's a #{parsed["courses"].size}-course menu paired to your wines."
    end

    if parsed.dig("cost_summary", "cost_per_cover")
      cpc = parsed["cost_summary"]["cost_per_cover"]
      budget = parsed.dig("cost_summary", "budget_per_cover")
      parts << "Estimated food cost: $#{'%.2f' % cpc}/cover"
      if budget
        diff = cpc - budget
        parts << (diff > 0 ? "($#{'%.2f' % diff} over budget)" : "($#{'%.2f' % diff.abs} under budget)")
      end
    end

    parts.join(" ")
  end

  def error_result(message)
    { display_content: message, structured_data: {}, error: true }
  end
end
