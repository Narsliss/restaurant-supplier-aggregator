# Normalizes supplier product names to canonical product names for grouping.
# The goal is to match products that are fundamentally "the same thing" even when
# supplier names differ in brand, size, or wording.
#
# Example: These should all match to canonical "Light Brown Sugar":
#   - "Domino Light Brown Sugar 50lb"
#   - "LIGHT BROWN SUGAR"
#   - "C&H Light Brown Sugar 25lb"
#   - "Brown Sugar, Light 12/2 LB"
#
class ProductNormalizer
  # Known brands to strip (add more as discovered)
  BRANDS = %w[
    domino c&h imperial dixie crystals monarch
    tyson perdue freebird pilgrim foster\ farms gerber gerbers wayne\ farms
    hormel oscar\ mayer smithfield brakebush ok\ foods vitale
    barilla dececco delallo ronzoni louisa
    sysco usfoods chefs\ warehouse ppo packer harbor\ banks
    grassland land\ o\ lakes kerrygold glenview\ farms trauth
    chaokoh coconut olivari
    beemster
    caputo king\ arthur gold\ medal
    trident blu\ lux fjord\ fresh
    cross\ valley labelle ibp bella\ bella broadleaf marrunga
    sasanian caviar\ star
    marzetti metro\ deli langs restaurantware roastworks viele\ street
    grand\ reserve plugra bridor cacao\ barry chocoa dawn\ foods
    vertical\ acres\ farm andy\ boy manns taylor\ farms
    dairyland frenchs fryfoods stock\ yards swift lanning\ foods
    allen\ brothers michaels avieta wholesome\ sweeteners classic\ cake
    minute\ maid coke sprite seagrams great\ lakes
    nounos\ creamery vermont\ creamery elle\ vire mitica spoleto teo
    fossil\ farms agrumato cargill
  ].freeze

  # Size/weight/count patterns to remove (package sizes, not product characteristics)
  # IMPORTANT: These must NOT match product-defining ranges like "21-25" shrimp counts
  SIZE_PATTERNS = [
    /\b\d+\s*-?\s*\d*\s*(oz|ounce|lb|lbs|pound|kg|g|gr|gram|gal|gallon|liter|litre|ml|pc|pcs|piece|pack|pk|case|ea|each)\b/i, # "8 oz", "8-10 oz"
    /\b\d+x\d+\s*(oz|lb)?\b/i,         # case packs like 4x5 or 4x10 LB
    /\bcase\s*-?\s*\d+.*?(lb|#|oz)?\b/i, # "Case - 12-2#" or "Case 12"
    /\b\d+\s*lb\s*case\b/i,            # "10 LB Case"
    /\b\d+\s*lba?\b/i,                 # "20 LBA"
    /\b\d+\s*ga?\b/i,                  # gallon like "1 GA"
    /\bpt\b/i,                         # pint
    /\b\d+"\b/,                        # size in inches like 1.5"
    /\b\d+\s*layer\s*box\b/i,          # "2 layer box"
    /\brib\b/i,                        # just "rib" as a packaging term
    /\b\d+\s*#\b/,                     # weight like 40#
    # Note: "count" is handled specially to preserve shrimp counts like "21-25 count"
    /\b(?<!\d-)\d+\s*(?:ct|count)\b/i, # count without preceding range
  ].freeze

  # Patterns to KEEP because they describe the product itself
  # These ratios, sizes, and counts are product characteristics, not package sizes
  KEEP_PATTERNS = [
    /\b\d+\/\d+\b/,                    # fat ratios like 81/19, 73/27
    /\b\d+-\d+\b/,                     # shrimp counts like 21-25, 26-30
    /\b\d+%\b/,                        # percentages like 36%, 40%
    /\b[abc]\s*size\b/i,               # sizing grades like "A size", "B size"
    /\b\d+x\d+\b/,                     # dimensions when not followed by units
  ].freeze

  # Words to strip that don't affect product identity
  NOISE_WORDS = %w[
    fresh frozen raw cooked ref refrigerated shelf\ stable
    vacuum pack vacuum-pack vac-pak netted rolled
    imported domestic wild farm\ raised farmed
    fillet filet portion cut loaf lobe
    bulk bag box tray bucket jar tin can
    plastic paper foil wrapped wrap solid
    grade aa
    bc foods layer
    ready previously fresh-to-frozen iqf ivp
    random
    prints print
  ].freeze

  # Grade/size letters to preserve (these distinguish products)
  PRESERVE_GRADES = %w[a b c size].freeze

  # Processing/preparation descriptors - keep these as they affect identity
  # (boneless chicken is different from bone-in chicken)
  KEEP_DESCRIPTORS = %w[
    boneless bone-in skinless skin-on
    sliced diced chopped whole ground minced shredded grated
    smoked cured brined marinated seasoned breaded
    organic antibiotic-free grass-fed pasture-raised free-range
    salted unsalted
    roasted raw blanched
  ].freeze

  def initialize(name, pack_size: nil)
    @original_name = name.to_s
    @pack_size = pack_size.to_s
  end

  # Returns a normalized canonical name suitable for matching
  def canonical_name
    @canonical_name ||= compute_canonical_name
  end

  # Returns a search-friendly base name (even more stripped down)
  def base_name
    @base_name ||= compute_base_name
  end

  # Returns extracted attributes
  def attributes
    @attributes ||= extract_attributes
  end

  # Find or create a canonical Product for this supplier product name
  def find_or_create_product(category: nil)
    canonical = canonical_name
    return nil if canonical.blank?

    # First, try exact match on canonical name
    product = Product.find_by("LOWER(normalized_name) = ?", canonical.downcase)
    return product if product

    # Try matching on base name (more aggressive normalization)
    base = base_name
    if base.present? && base.split.size >= 2
      # Find products whose base name matches
      candidates = Product.where("normalized_name IS NOT NULL")
      product = candidates.find do |p|
        other_base = self.class.new(p.name).base_name
        base.downcase == other_base.downcase
      end
      return product if product
    end

    # No match found - create a new canonical product
    # Use a cleaned-up version of the original name
    display_name = titleize_product_name(canonical)

    Product.create!(
      name: display_name,
      normalized_name: canonical.downcase.gsub(/[^a-z0-9\s]/, "").squish,
      category: category || guess_category(canonical)
    )
  end

  private

  def compute_canonical_name
    name = @original_name.dup

    # Lowercase for processing
    name = name.downcase

    # Extract and preserve important patterns before stripping
    preserved = []
    KEEP_PATTERNS.each do |pattern|
      name.scan(pattern).each { |match| preserved << match }
    end

    # Remove brand names
    BRANDS.each do |brand|
      name = name.gsub(/\b#{Regexp.escape(brand)}\b/i, " ")
    end

    # Remove size/weight patterns (package sizes, not product characteristics)
    SIZE_PATTERNS.each do |pattern|
      name = name.gsub(pattern, " ")
    end

    # Remove noise words
    NOISE_WORDS.each do |word|
      name = name.gsub(/\b#{Regexp.escape(word)}\b/i, " ")
    end

    # Remove common suffixes/prefixes that are just catalog noise
    name = name.gsub(/\b(fi-bl|fi-bb|pbo)\b/i, " ")  # catalog codes
    name = name.gsub(/-to-/i, " ")                     # "fresh-to-frozen" leftover
    name = name.gsub(/\s*-\s*$/, "")                   # trailing dash
    name = name.gsub(/^\s*-\s*/, "")                   # leading dash

    # Normalize punctuation (but preserve slashes and dashes in ratios/ranges)
    name = name.gsub(/[,]/, " ")

    # Remove special chars but keep digits, slashes, and dashes (for ratios and ranges)
    name = name.gsub(/[^a-z0-9\s\/\-]/, "")
    name = name.squish

    # Clean up isolated dashes (not part of ranges like 21-25)
    name = name.gsub(/\s+-\s+/, " ")     # " - " → " "
    name = name.gsub(/^-\s*/, "")        # leading dash
    name = name.gsub(/\s*-$/, "")        # trailing dash

    # Remove only standalone single digits (not part of ranges/ratios)
    # Keep: 81/19, 21-25, 36, etc.
    name = name.gsub(/(?<![0-9\/\-])\b\d\b(?![0-9\/\-])/, " ").squish

    # Reorder common patterns: "Sugar, Brown Light" → "Light Brown Sugar"
    name = reorder_inverted_name(name)

    name
  end

  def compute_base_name
    name = canonical_name

    # Strip even the descriptors for the most generic match
    KEEP_DESCRIPTORS.each do |desc|
      name = name.gsub(/\b#{Regexp.escape(desc)}\b/i, " ")
    end

    name.squish
  end

  def extract_attributes
    attrs = {}

    # Extract brand
    BRANDS.each do |brand|
      if @original_name.downcase.include?(brand)
        attrs[:brand] = brand.titleize
        break
      end
    end

    # Extract processing descriptors
    descriptors = KEEP_DESCRIPTORS.select do |desc|
      @original_name.downcase.include?(desc)
    end
    attrs[:descriptors] = descriptors if descriptors.any?

    # Extract organic/special designations
    attrs[:organic] = true if @original_name.downcase.include?("organic")
    attrs[:antibiotic_free] = true if @original_name.downcase.match?(/antibiotic.?free/)

    attrs
  end

  # Handle inverted names like "Chicken, Breast Boneless" → "Boneless Chicken Breast"
  # Also handles "Sugar Brown Light" → "Light Brown Sugar"
  def reorder_inverted_name(name)
    words = name.split
    return name if words.size < 2

    # Find descriptor words and main product words
    descriptors = []
    main_words = []
    modifiers = []  # words like "light", "dark", "white", "red" that modify the product

    color_modifiers = %w[light dark white brown red yellow green black golden]

    words.each do |word|
      if KEEP_DESCRIPTORS.include?(word)
        descriptors << word
      elsif color_modifiers.include?(word)
        modifiers << word
      else
        main_words << word
      end
    end

    # Put descriptors first, then modifiers, then main words
    # This turns "sugar brown light" → "light brown sugar"
    (descriptors + modifiers + main_words).join(" ")
  end

  def titleize_product_name(name)
    # Capitalize each word, but handle special cases
    name.split.map do |word|
      case word.downcase
      when "and", "or", "with", "in", "of", "for", "to", "a", "an", "the"
        word.downcase
      else
        word.capitalize
      end
    end.join(" ")
  end

  def guess_category(name)
    n = name.downcase
    return "Poultry" if n.match?(/chicken|turkey|duck|poultry|wing|thigh|breast/)
    return "Meat" if n.match?(/beef|steak|pork|lamb|veal|bacon|sausage|ground|rib|loin|chop|elk|venison/)
    return "Seafood" if n.match?(/salmon|shrimp|fish|tuna|crab|lobster|oyster|clam|scallop|cod|tilapia|mahi|caviar|trout|roe/)
    return "Produce" if n.match?(/lettuce|tomato|onion|potato|carrot|pepper|garlic|herb|mushroom|avocado|lemon|lime|apple|berry|fruit|vegetable|greens|kale|spinach|celery|cucumber|squash|cabbage/)
    return "Dairy" if n.match?(/milk|cream|cheese|butter|yogurt|egg|mozzarella|parmesan|cheddar|gouda/)
    return "Bakery" if n.match?(/bread|roll|bun|tortilla|pastry|cake|cookie|muffin|croissant/)
    return "Dry Goods" if n.match?(/flour|sugar|rice|pasta|oil|vinegar|sauce|spice|salt|pepper|seasoning|tortellini|rigatoni/)
    return "Beverages" if n.match?(/water|juice|soda|coffee|tea|wine|beer/)
    return "Frozen" if n.match?(/frozen|ice cream|sorbet/)
    nil
  end

  class << self
    # Convenience method to normalize a name
    def normalize(name, pack_size: nil)
      new(name, pack_size: pack_size).canonical_name
    end

    # Calculate similarity score between two product names (0.0 to 1.0)
    def similarity(name1, name2)
      n1 = new(name1)
      n2 = new(name2)

      canonical1 = n1.canonical_name.downcase.split.to_set
      canonical2 = n2.canonical_name.downcase.split.to_set

      return 0.0 if canonical1.empty? || canonical2.empty?

      intersection = canonical1 & canonical2
      union = canonical1 | canonical2

      # Jaccard similarity
      intersection.size.to_f / union.size
    end

    # Check if two products are likely the same (>= 0.75 similarity)
    # Using 0.75 to avoid false positives on products that differ only by
    # size count (21-25 vs 26-30 shrimp) or ratio (81/19 vs 73/27 ground beef)
    def same_product?(name1, name2, threshold: 0.75)
      similarity(name1, name2) >= threshold
    end
  end
end
