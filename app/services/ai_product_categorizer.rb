class AiProductCategorizer
  CATEGORIES = {
    "Meat" => {
      description: "Beef, pork, lamb, veal, game meats",
      subcategories: ["Beef", "Pork", "Lamb", "Veal", "Game", "Ground Meat", "Processed Meat"]
    },
    "Poultry" => {
      description: "Chicken, turkey, duck, and other poultry products",
      subcategories: ["Chicken", "Turkey", "Duck", "Cornish Hen", "Ground Poultry"]
    },
    "Seafood" => {
      description: "Fish, shellfish, and other seafood",
      subcategories: ["Fish", "Shellfish", "Crustaceans", "Mollusks", "Smoked/Cured", "Caviar/Roe"]
    },
    "Produce" => {
      description: "Fresh fruits and vegetables",
      subcategories: ["Vegetables", "Fruits", "Herbs", "Mushrooms", "Salad Greens", "Root Vegetables"]
    },
    "Dairy" => {
      description: "Milk, cheese, butter, cream, eggs, and dairy products",
      subcategories: ["Milk/Cream", "Cheese", "Butter", "Eggs", "Yogurt", "Specialty Dairy"]
    },
    "Bakery" => {
      description: "Breads, rolls, pastries, and baked goods",
      subcategories: ["Bread", "Rolls/Buns", "Tortillas", "Pastries", "Desserts", "Frozen Dough"]
    },
    "Dry Goods" => {
      description: "Pasta, rice, grains, flour, sugar, and shelf-stable items",
      subcategories: ["Pasta", "Rice/Grains", "Flour/Baking", "Sugar/Sweeteners", "Beans/Legumes", "Cereals"]
    },
    "Oils & Condiments" => {
      description: "Cooking oils, vinegars, sauces, dressings, and condiments",
      subcategories: ["Oils", "Vinegars", "Sauces", "Dressings", "Condiments", "Marinades"]
    },
    "Spices & Seasonings" => {
      description: "Spices, herbs, seasonings, and flavor enhancers",
      subcategories: ["Spices", "Dried Herbs", "Blends", "Salt/Pepper", "Extracts"]
    },
    "Beverages" => {
      description: "Drinks including water, juices, coffee, tea",
      subcategories: ["Water", "Juices", "Coffee", "Tea", "Soft Drinks", "Mixers"]
    },
    "Frozen" => {
      description: "Frozen foods, ice cream, frozen desserts",
      subcategories: ["Frozen Entrees", "Ice Cream", "Frozen Vegetables", "Frozen Fruits", "Frozen Desserts"]
    },
    "Canned & Jarred" => {
      description: "Canned vegetables, fruits, soups, and preserved items",
      subcategories: ["Canned Vegetables", "Canned Fruits", "Soups/Stocks", "Tomato Products", "Pickled Items"]
    },
    "Paper & Disposables" => {
      description: "Paper products, disposable containers, and supplies",
      subcategories: ["Paper Products", "To-Go Containers", "Utensils", "Bags", "Gloves"]
    },
    "Cleaning & Sanitation" => {
      description: "Cleaning supplies and sanitation products",
      subcategories: ["Cleaners", "Sanitizers", "Dish Care", "Floor Care"]
    },
    "Equipment & Smallwares" => {
      description: "Kitchen equipment, tools, and smallwares",
      subcategories: ["Cookware", "Utensils", "Storage", "Prep Tools"]
    }
  }.freeze

  class << self
    def categorize(product_name, batch: false)
      return nil if product_name.blank?

      # First try fast rule-based categorization
      result = rule_based_categorize(product_name)
      return result if result[:category].present? && result[:confidence] >= 0.8

      # Fall back to AI if rules are uncertain
      ai_categorize(product_name)
    end

    def categorize_batch(product_names)
      return [] if product_names.blank?

      # Batch categorize using AI for efficiency
      ai_categorize_batch(product_names)
    end

    def rule_based_categorize(name)
      n = name.downcase

      # Poultry patterns
      if n.match?(/\b(chicken|turkey|duck|cornish|poultry)\b/)
        subcategory = detect_poultry_subcategory(n)
        return { category: "Poultry", subcategory: subcategory, confidence: 0.9 }
      end

      # Meat patterns
      if n.match?(/\b(beef|steak|pork|lamb|veal|bacon|sausage|ham|rib|loin|chop|roast|brisket|tenderloin|sirloin|ribeye|filet|primal|elk|venison|bison|hot\s*dog|guanciale|coppa|pancetta|prosciutto|salami|chuck|flap|short\s*rib|pastrami|wagyu|corned)\b/)
        subcategory = detect_meat_subcategory(n)
        return { category: "Meat", subcategory: subcategory, confidence: 0.9 }
      end

      # Seafood patterns
      if n.match?(/\b(salmon|shrimp|fish|tuna|crab|lobster|oyster|clam|scallop|cod|tilapia|mahi|caviar|trout|roe|halibut|snapper|bass|swordfish|calamari|squid|octopus|mussel|prawn|crawfish|crayfish|anchovie|sardine|mackerel|flounder|sole|perch|catfish)\b/)
        subcategory = detect_seafood_subcategory(n)
        return { category: "Seafood", subcategory: subcategory, confidence: 0.9 }
      end

      # Dairy patterns
      if n.match?(/\b(milk|cream|cheese|butter|yogurt|egg|mozzarella|parmesan|cheddar|gouda|brie|feta|ricotta|provolone|swiss|goat\s*cheese|cream\s*cheese|sour\s*cream|half\s*(and|&)\s*half|whipping|cottage|mascarpone|creme\s*fraiche|crema|queso|pecorino|gruyere|fontina|asiago|gorgonzola|burrata|stracciatella|oat\s*milk|almond\s*milk|barista|wensleydale|stilton|camembert|manchego|havarti)\b/)
        subcategory = detect_dairy_subcategory(n)
        return { category: "Dairy", subcategory: subcategory, confidence: 0.9 }
      end

      # Produce patterns
      if n.match?(/\b(lettuce|tomato|tomatillo|onion|potato|carrot|pepper|garlic|mushroom|avocado|lemon|lime|apple|berry|fruit|vegetable|greens|kale|spinach|celery|cucumber|squash|cabbage|broccoli|cauliflower|asparagus|artichoke|beet|radish|turnip|parsnip|zucchini|eggplant|corn|pea|bean|sprout|cilantro|parsley|basil|mint|dill|rosemary|thyme|sage|chive|arugula|chard|romaine|iceberg|mesclun|radicchio|endive|leeks?|shallots?|scallion|apricots?|peach|plum|pear|mango|papaya|melon|grape|cherry|orange|grapefruit|fennel|frisee|watercress|salad|pico\s*de\s*gallo|flower|blossom|sauerkraut)\b/)
        subcategory = detect_produce_subcategory(n)
        return { category: "Produce", subcategory: subcategory, confidence: 0.85 }
      end

      # Bakery patterns
      if n.match?(/\b(bread|roll|bun|tortilla|pastry|cake|cookie|muffin|croissant|bagel|donut|danish|pie|tart|brioche|focaccia|ciabatta|baguette|sourdough|pita|naan|flatbread)\b/)
        subcategory = detect_bakery_subcategory(n)
        return { category: "Bakery", subcategory: subcategory, confidence: 0.85 }
      end

      # Dry Goods patterns
      if n.match?(/\b(flour|sugar|rice|pasta|spaghetti|penne|rigatoni|linguine|fettuccine|macaroni|noodle|quinoa|couscous|barley|oat|wheat|cornmeal|polenta|grits|maple\s*syrup|honey|molasses|chocolate)\b/)
        subcategory = detect_dry_goods_subcategory(n)
        return { category: "Dry Goods", subcategory: subcategory, confidence: 0.85 }
      end

      # Oils & Condiments
      if n.match?(/\b(oil|olive|canola|vegetable\s*oil|vinegar|balsamic|sauce|ketchup|mustard|mayo|mayonnaise|dressing|marinade|teriyaki|soy\s*sauce|worcestershire|hot\s*sauce|bbq|sriracha|aioli|pesto)\b/)
        subcategory = detect_condiment_subcategory(n)
        return { category: "Oils & Condiments", subcategory: subcategory, confidence: 0.85 }
      end

      # Spices & Seasonings
      if n.match?(/\b(spice|seasoning|salt|pepper|paprika|cumin|oregano|cinnamon|nutmeg|ginger|turmeric|curry|chili|cayenne|coriander|fennel|cardamom|clove|allspice|vanilla|extract)\b/)
        subcategory = detect_spice_subcategory(n)
        return { category: "Spices & Seasonings", subcategory: subcategory, confidence: 0.85 }
      end

      # Beverages
      if n.match?(/\b(water|juice|soda|coffee|tea|lemonade|iced\s*tea|espresso|cold\s*brew)\b/)
        subcategory = detect_beverage_subcategory(n)
        return { category: "Beverages", subcategory: subcategory, confidence: 0.85 }
      end

      # Frozen (check last since other categories may have frozen variants)
      if n.match?(/\b(frozen|ice\s*cream|sorbet|gelato|popsicle)\b/)
        return { category: "Frozen", subcategory: "Frozen", confidence: 0.7 }
      end

      # Canned & Jarred
      if n.match?(/\b(canned|can\s*of|jarred|pickled|preserved|stock|broth|soup|passata|puree|crushed\s*tomato|diced\s*tomato|tomato\s*paste)\b/)
        return { category: "Canned & Jarred", subcategory: "Tomato Products", confidence: 0.8 }
      end

      # Paper & Disposables
      if n.match?(/\b(paper|napkin|towel|container|to-?go|disposable|foam|plastic\s*(cup|container)|bag|glove)\b/)
        return { category: "Paper & Disposables", subcategory: nil, confidence: 0.8 }
      end

      # Cleaning
      if n.match?(/\b(cleaner|sanitizer|soap|detergent|bleach|disinfect)\b/)
        return { category: "Cleaning & Sanitation", subcategory: nil, confidence: 0.85 }
      end

      # No confident match
      { category: nil, subcategory: nil, confidence: 0.0 }
    end

    private

    def ai_categorize(product_name)
      client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])

      response = client.chat(
        parameters: {
          model: "gpt-4o-mini",
          messages: [
            { role: "system", content: system_prompt },
            { role: "user", content: "Categorize this restaurant supply product: #{product_name}" }
          ],
          temperature: 0.1,
          max_tokens: 100
        }
      )

      parse_ai_response(response.dig("choices", 0, "message", "content"))
    rescue => e
      Rails.logger.error "[AiProductCategorizer] AI categorization failed: #{e.message}"
      { category: nil, subcategory: nil, confidence: 0.0 }
    end

    def ai_categorize_batch(product_names)
      client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])

      # Chunk into batches of 20 for efficiency
      results = []
      product_names.each_slice(20) do |batch|
        batch_prompt = batch.map.with_index { |name, i| "#{i + 1}. #{name}" }.join("\n")

        response = client.chat(
          parameters: {
            model: "gpt-4o-mini",
            messages: [
              { role: "system", content: batch_system_prompt },
              { role: "user", content: "Categorize these restaurant supply products:\n\n#{batch_prompt}" }
            ],
            temperature: 0.1,
            max_tokens: 1500
          }
        )

        batch_results = parse_batch_ai_response(response.dig("choices", 0, "message", "content"), batch.size)
        results.concat(batch_results)
      end

      results
    rescue => e
      Rails.logger.error "[AiProductCategorizer] Batch AI categorization failed: #{e.message}"
      product_names.map { { category: nil, subcategory: nil, confidence: 0.0 } }
    end

    def system_prompt
      categories_list = CATEGORIES.map { |cat, info| "- #{cat}: #{info[:description]}" }.join("\n")

      <<~PROMPT
        You are a product categorization assistant for a restaurant supply platform.
        Categorize the given product into one of these categories:

        #{categories_list}

        Respond in this exact format:
        Category: [category name]
        Subcategory: [subcategory or "None"]

        Choose the most specific appropriate category. For example:
        - "Frozen Chicken Wings" should be "Poultry" not "Frozen"
        - "Canned Tomatoes" should be "Canned & Jarred"
        - "Fresh Basil" should be "Produce" with subcategory "Herbs"
      PROMPT
    end

    def batch_system_prompt
      categories_list = CATEGORIES.map { |cat, info| "- #{cat}: #{info[:description]}" }.join("\n")

      <<~PROMPT
        You are a product categorization assistant for a restaurant supply platform.
        Categorize each product into one of these categories:

        #{categories_list}

        Respond with one line per product in this exact format:
        1. Category: [category] | Subcategory: [subcategory or None]
        2. Category: [category] | Subcategory: [subcategory or None]
        etc.

        Choose the most specific appropriate category.
      PROMPT
    end

    def parse_ai_response(content)
      return { category: nil, subcategory: nil, confidence: 0.0 } if content.blank?

      category_match = content.match(/Category:\s*(.+?)(?:\n|$)/i)
      subcategory_match = content.match(/Subcategory:\s*(.+?)(?:\n|$)/i)

      category = category_match&.[](1)&.strip
      subcategory = subcategory_match&.[](1)&.strip
      subcategory = nil if subcategory&.downcase == "none"

      # Validate category exists
      if category && CATEGORIES.key?(category)
        { category: category, subcategory: subcategory, confidence: 0.85 }
      else
        { category: nil, subcategory: nil, confidence: 0.0 }
      end
    end

    def parse_batch_ai_response(content, expected_count)
      return Array.new(expected_count) { { category: nil, subcategory: nil, confidence: 0.0 } } if content.blank?

      results = []
      content.each_line do |line|
        if line.match?(/^\d+\.\s*Category:/i)
          category_match = line.match(/Category:\s*([^|]+)/i)
          subcategory_match = line.match(/Subcategory:\s*(.+?)(?:\n|$)/i)

          category = category_match&.[](1)&.strip
          subcategory = subcategory_match&.[](1)&.strip
          subcategory = nil if subcategory&.downcase == "none"

          if category && CATEGORIES.key?(category)
            results << { category: category, subcategory: subcategory, confidence: 0.85 }
          else
            results << { category: nil, subcategory: nil, confidence: 0.0 }
          end
        end
      end

      # Pad with empty results if we didn't get enough
      while results.size < expected_count
        results << { category: nil, subcategory: nil, confidence: 0.0 }
      end

      results
    end

    # Subcategory detection helpers
    def detect_poultry_subcategory(name)
      return "Turkey" if name.match?(/turkey/)
      return "Duck" if name.match?(/duck/)
      return "Cornish Hen" if name.match?(/cornish/)
      return "Ground Poultry" if name.match?(/ground/)
      "Chicken"
    end

    def detect_meat_subcategory(name)
      return "Beef" if name.match?(/beef|steak|ribeye|sirloin|brisket|filet/)
      return "Pork" if name.match?(/pork|bacon|ham/)
      return "Lamb" if name.match?(/lamb/)
      return "Veal" if name.match?(/veal/)
      return "Game" if name.match?(/elk|venison|bison/)
      return "Ground Meat" if name.match?(/ground/)
      return "Processed Meat" if name.match?(/sausage|hot\s*dog/)
      "Beef"
    end

    def detect_seafood_subcategory(name)
      return "Shellfish" if name.match?(/shrimp|prawn|crawfish|crayfish/)
      return "Crustaceans" if name.match?(/crab|lobster/)
      return "Mollusks" if name.match?(/oyster|clam|mussel|scallop|squid|calamari|octopus/)
      return "Caviar/Roe" if name.match?(/caviar|roe/)
      return "Smoked/Cured" if name.match?(/smoked|cured|lox/)
      "Fish"
    end

    def detect_dairy_subcategory(name)
      return "Cheese" if name.match?(/cheese|mozzarella|parmesan|cheddar|gouda|brie|feta|ricotta|provolone|swiss/)
      return "Butter" if name.match?(/butter/)
      return "Eggs" if name.match?(/egg/)
      return "Yogurt" if name.match?(/yogurt/)
      return "Milk/Cream" if name.match?(/milk|cream|half/)
      "Specialty Dairy"
    end

    def detect_produce_subcategory(name)
      return "Herbs" if name.match?(/cilantro|parsley|basil|mint|dill|rosemary|thyme|sage|chive|herb/)
      return "Mushrooms" if name.match?(/mushroom/)
      return "Salad Greens" if name.match?(/lettuce|arugula|chard|romaine|iceberg|mesclun|radicchio|endive|greens|spinach|kale/)
      return "Root Vegetables" if name.match?(/potato|carrot|beet|radish|turnip|parsnip|onion|garlic/)
      return "Fruits" if name.match?(/apple|berry|lemon|lime|orange|fruit|avocado|tomato/)
      "Vegetables"
    end

    def detect_bakery_subcategory(name)
      return "Bread" if name.match?(/bread|sourdough|ciabatta|baguette|focaccia/)
      return "Rolls/Buns" if name.match?(/roll|bun/)
      return "Tortillas" if name.match?(/tortilla|pita|naan|flatbread/)
      return "Pastries" if name.match?(/pastry|croissant|danish|donut|brioche/)
      return "Desserts" if name.match?(/cake|cookie|muffin|pie|tart/)
      "Bread"
    end

    def detect_dry_goods_subcategory(name)
      return "Pasta" if name.match?(/pasta|spaghetti|penne|rigatoni|linguine|fettuccine|macaroni|noodle/)
      return "Rice/Grains" if name.match?(/rice|quinoa|couscous|barley|oat|wheat|grain/)
      return "Flour/Baking" if name.match?(/flour|cornmeal|polenta/)
      return "Sugar/Sweeteners" if name.match?(/sugar|honey|syrup|sweetener/)
      "Rice/Grains"
    end

    def detect_condiment_subcategory(name)
      return "Oils" if name.match?(/oil|olive|canola/)
      return "Vinegars" if name.match?(/vinegar|balsamic/)
      return "Sauces" if name.match?(/sauce|teriyaki|soy|worcestershire|hot\s*sauce|bbq|sriracha/)
      return "Dressings" if name.match?(/dressing/)
      return "Condiments" if name.match?(/ketchup|mustard|mayo|aioli/)
      return "Marinades" if name.match?(/marinade|pesto/)
      "Condiments"
    end

    def detect_spice_subcategory(name)
      return "Salt/Pepper" if name.match?(/salt|pepper/)
      return "Blends" if name.match?(/seasoning|blend|rub/)
      return "Extracts" if name.match?(/extract|vanilla/)
      "Spices"
    end

    def detect_beverage_subcategory(name)
      return "Coffee" if name.match?(/coffee|espresso|cold\s*brew/)
      return "Tea" if name.match?(/tea/)
      return "Juices" if name.match?(/juice|lemonade/)
      return "Soft Drinks" if name.match?(/soda/)
      "Water"
    end
  end
end
