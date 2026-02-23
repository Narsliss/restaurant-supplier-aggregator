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

      # NOTE: Patterns use \b only at the START (word boundary) and allow plural/suffix
      # matching by omitting \b at the end. This ensures "mushrooms", "avocados",
      # "blueberries" etc. all match correctly.

      # Poultry patterns (check before meat to avoid "chicken" matching "chop")
      if n.match?(/\b(chicken|turkey|duck|cornish|poultry)\b/)
        subcategory = detect_poultry_subcategory(n)
        return { category: "Poultry", subcategory: subcategory, confidence: 0.9 }
      end

      # Meat patterns
      if n.match?(/\b(beef|steak|pork|lamb|veal|bacon|sausage|ham\b|rib\b|loin|chop|roast|brisket|tenderloin|sirloin|ribeye|filet|primal|elk|venison|bison|hot\s*dog|guanciale|coppa|pancetta|prosciutto|salami|salame|chuck|flap|short\s*rib|pastrami|wagyu|corned|pepperoni|chorizo|bresaola|nduja|mortadella|sopressata|speck|mett)/)
        subcategory = detect_meat_subcategory(n)
        return { category: "Meat", subcategory: subcategory, confidence: 0.9 }
      end

      # Seafood patterns
      if n.match?(/\b(salmon|shrimp|fish|tuna|crab|lobster|oyster|clam|scallop|cod\b|tilapia|mahi|caviar|trout|roe\b|halibut|snapper|bass\b|swordfish|calamari|squid|octopus|mussel|prawn|crawfish|crayfish|anchov|sardine|mackerel|flounder|sole\b|perch|catfish|grouper|redfish|branzino|monkfish|wahoo|escolar|eel\b|uni\b|ceviche|sheepshead|skate\b|shark\b|krabb)/)
        subcategory = detect_seafood_subcategory(n)
        return { category: "Seafood", subcategory: subcategory, confidence: 0.9 }
      end

      # Dairy patterns
      if n.match?(/\b(milk|cream(?!er)|cheese|butter|yogurt|egg\b|eggs\b|mozzarella|parmesan|cheddar|gouda|brie\b|feta|ricotta|provolone|swiss|goat\s*cheese|cream\s*cheese|sour\s*cream|half\s*(and|&)\s*half|whipping|cottage|mascarpone|creme\s*fraiche|crema|queso|pecorino|gruyere|fontina|asiago|gorgonzola|burrata|stracciatella|oat\s*milk|almond\s*milk|barista|wensleydale|stilton|camembert|manchego|havarti|margarine)/)
        subcategory = detect_dairy_subcategory(n)
        return { category: "Dairy", subcategory: subcategory, confidence: 0.9 }
      end

      # Produce patterns (broad — fruits, vegetables, herbs, mushrooms)
      if n.match?(/\b(lettuce|tomato|tomatillo|onion|potato|carrot|pepper(?!oni)|garlic|mushroom|portabella|portobello|crimini|shiitake|avocado|lemon|lime\b|apple|berry|berries|blueberr|strawberr|raspberr|blackberr|cranberr|fruit|vegetable|greens|kale|spinach|celery|cucumber|squash|cabbage|broccoli|cauliflower|asparagus|artichoke|beet\b|beets|radish|turnip|parsnip|zucchini|eggplant|corn\b|pea\b|peas\b|bean\b|beans\b|sprout|cilantro|parsley|basil|mint\b|dill\b|rosemary|thyme|sage\b|chive|chervil|arugula|chard|romaine|iceberg|mesclun|radicchio|endive|leek|shallot|scallion|apricot|peach|plum\b|pear\b|mango|papaya|melon|watermelon|cantaloupe|honeydew|grape(?!fruit)|cherry|cherries|orange|grapefruit|fennel|frisee|watercress|salad|pico\s*de\s*gallo|flower|blossom|sauerkraut|pineapple|coconut|date\b|dates\b|fig\b|figs\b|nectarine|kiwi|pomegranate|plantain|guacamole|jicama|celeriac|kohlrabi|ramp\b|ramps\b|chayote|taro|yuca|cassava|edamame|bok\s*choy|daikon|jalapeno|habanero|serrano|poblano|hatch|brussels|saffron|peppercorn|rhubarb|persimmon|lychee|passion\s*fruit|dragonfruit|clementine|tangerine|kumquat|microgreen|cress|tarragon|lemongrass|ginger\b|turmeric\b|truffle|horseradish|chile|chili)/)
        subcategory = detect_produce_subcategory(n)
        return { category: "Produce", subcategory: subcategory, confidence: 0.85 }
      end

      # Bakery patterns
      if n.match?(/\b(bread|roll\b|rolls\b|bun\b|buns\b|tortilla|pastry|cake|cookie|muffin|croissant|bagel|donut|danish|pie\b|pies\b|tart\b|brioche|focaccia|ciabatta|baguette|sourdough|pita|naan|flatbread|eclair|beignet|scone|biscuit|waffle|pancake|crepe|crumble|strudel|filo|phyllo|dough|crust)/)
        subcategory = detect_bakery_subcategory(n)
        return { category: "Bakery", subcategory: subcategory, confidence: 0.85 }
      end

      # Dry Goods patterns
      if n.match?(/\b(flour|sugar|rice\b|pasta|spaghetti|penne|rigatoni|linguine|fettuccine|macaroni|noodle|quinoa|couscous|barley|oat|wheat|cornmeal|polenta|grits|maple\s*syrup|honey|molasses|chocolate|cocoa|cacao|cornstarch|baking\s*(soda|powder)|yeast|gelatin|pudding|raisin|granola|cereal|cracker|pretzel|chip\b|chips\b|popcorn|nut\b|nuts\b|almond\b|almonds\b|pecan|walnut|cashew|pistachio|peanut|hazelnut|nutella|spread|syrup|agave|sweetener|lasagna|panko|breadcrumb|crouton|couscous|lentil|chickpea|farro|millet|amaranth|tapioca|sago)/)
        subcategory = detect_dry_goods_subcategory(n)
        return { category: "Dry Goods", subcategory: subcategory, confidence: 0.85 }
      end

      # Oils & Condiments
      if n.match?(/\b(oil\b|oils\b|olive\b|olives\b|canola|vegetable\s*oil|vinegar|balsamic|sauce|ketchup|mustard|mayo|mayonnaise|dressing|marinade|teriyaki|soy\s*sauce|worcestershire|hot\s*sauce|bbq|sriracha|aioli|pesto|jam\b|jelly|preserve|marmalade|relish|chutney|hummus|tahini|miso|sambal|gochujang|harissa|chimichurri|tzatziki|remoulade|tapenade|bruschetta|salsa|guava|tamarind|ponzu|hoisin|fish\s*sauce|oyster\s*sauce|chili\s*oil|sesame\s*oil|truffle\s*oil|compound\s*butter)/)
        subcategory = detect_condiment_subcategory(n)
        return { category: "Oils & Condiments", subcategory: subcategory, confidence: 0.85 }
      end

      # Spices & Seasonings
      if n.match?(/\b(spice|seasoning|salt\b|pepper\b|paprika|cumin|oregano|cinnamon|nutmeg|turmeric|curry|cayenne|coriander|cardamom|clove|allspice|vanilla|extract|anise|star\s*anise|sumac|za.atar|smoked\s*paprika|old\s*bay|tajin|msg|bouillon|ancho|chipotle\s*powder|chile\s*powder|chili\s*powder|rub\b|dry\s*rub)/)
        subcategory = detect_spice_subcategory(n)
        return { category: "Spices & Seasonings", subcategory: subcategory, confidence: 0.85 }
      end

      # Beverages
      if n.match?(/\b(water\b|juice|soda|coffee|tea\b|teas\b|lemonade|iced\s*tea|espresso|cold\s*brew|kombucha|chai|smoothie|cocoa\s*mix|hot\s*chocolate|cider|tonic|seltzer|sparkling|pellegrino|perrier|mineral\s*water)/)
        subcategory = detect_beverage_subcategory(n)
        return { category: "Beverages", subcategory: subcategory, confidence: 0.85 }
      end

      # Canned & Jarred (before Frozen — "canned" goods take priority)
      if n.match?(/\b(canned|can\s*of|jarred|pickled|preserved|stock|broth|soup|passata|puree|crushed\s*tomato|diced\s*tomato|tomato\s*paste|pimiento|roasted\s*pepper|caper|anchov|artichoke\s*heart|hearts\s*of\s*palm|bamboo\s*shoot|water\s*chestnut|chipotle\s*in|adobo|coconut\s*milk|coconut\s*cream|evaporated|condensed\s*milk)/)
        return { category: "Canned & Jarred", subcategory: nil, confidence: 0.8 }
      end

      # Frozen (check after other food categories — many foods are frozen variants)
      if n.match?(/\b(frozen|ice\s*cream|sorbet|gelato|popsicle|iqf|fries\b|fry\b|tot\b|nugget|patties|patty)/)
        return { category: "Frozen", subcategory: "Frozen", confidence: 0.7 }
      end

      # Equipment & Smallwares
      if n.match?(/\b(pan\b|pans\b|pot\b|pots\b|skillet|griddle|wok\b|sheet\s*pan|steam\s*table|hotel\s*pan|ramekin|underliner|tong|whisk|spatula|ladle|peeler|thermometer|scale\b|cutting\s*board|rack\b|broom|mop\b|bucket|dust\s*pan|mitt\b|apron|chef.s?\s*coat|handle|scrubber|grill\s*brick|grill\s*screen|fuel|chafing|chafer|trivet|mandoline|sieve|strainer|colander|sheet\b.*aluminum|fry\s*pan|sauce\s*pan|saute\s*pan|roasting\s*pan|stockpot|hotel)/)
        return { category: "Equipment & Smallwares", subcategory: nil, confidence: 0.8 }
      end

      # Paper & Disposables
      if n.match?(/\b(napkin|paper\s*towel|container.*oz|to-?go|disposable|foam\b|cup\b|cups\b|lid\b|lids\b|straw\b|straws\b|bag\b|bags\b|glove|wrapper|wrap\b|wraps\b|foil\b|film\b|parchment|wax\s*paper|boat\b|boats\b|cutlery\s*kit|portion\s*cup|souffle\s*cup|plate\b|plates\b|tray\b|trays\b|bowl\b|bowls\b|fork\b|forks\b|knife\b|knives\b|spoon\b|spoons\b|compostable|polystyrene|takeout|take-?out|clamshell|deli\s*paper|freezer\s*paper|pizza\s*circle|pizza\s*box|liner\b|hairnet|food\s*tray|towelette|tumbler)/)
        return { category: "Paper & Disposables", subcategory: nil, confidence: 0.8 }
      end

      # Cleaning & Sanitation
      if n.match?(/\b(cleaner|sanitizer|soap|detergent|bleach|disinfect|degreaser|wipe\b|wipes\b|scouring|scrub\s*pad|steel\s*wool|dish\s*care|floor\s*care|hand\s*wash|rinse\s*aid)/)
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
