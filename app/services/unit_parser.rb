# Parses free-text pack_size strings from supplier products into structured
# quantities with normalized units for apples-to-apples price comparison.
#
# Examples:
#   UnitParser.parse("50 LB")        => { quantity: 50, unit: "lb", normalized_quantity: 800, normalized_unit: "oz", parseable: true }
#   UnitParser.parse("16 oz")        => { quantity: 16, unit: "oz", normalized_quantity: 16, normalized_unit: "oz", parseable: true }
#   UnitParser.parse("1 GAL")        => { quantity: 1, unit: "gal", normalized_quantity: 128, normalized_unit: "fl oz", parseable: true }
#   UnitParser.parse("4x10 oz")      => { quantity: 40, unit: "oz", normalized_quantity: 40, normalized_unit: "oz", parseable: true }
#   UnitParser.parse("Case - 12-2#") => { quantity: 24, unit: "lb", normalized_quantity: 384, normalized_unit: "oz", parseable: true }
#   UnitParser.parse("15 DZ")        => { quantity: 15, unit: "dz", normalized_quantity: 180, normalized_unit: "each", parseable: true }
#   UnitParser.parse("1 DOZEN")      => { quantity: 1, unit: "dz", normalized_quantity: 12, normalized_unit: "each", parseable: true }
#   UnitParser.parse("BUNCH")        => { quantity: 1, unit: "bunch", normalized_quantity: 1, normalized_unit: "bunch", parseable: true }
#
class UnitParser
  # Weight conversions to ounces
  # Note: bare "g" is NOT grams in food service — it means gallons (see VOLUME_TO_FL_OZ).
  # Grams use "gr", "gram", or "grams" in supplier pack sizes.
  WEIGHT_TO_OZ = {
    "oz" => 1.0,
    "ounce" => 1.0,
    "ounces" => 1.0,
    "lb" => 16.0,
    "lbs" => 16.0,
    "pound" => 16.0,
    "pounds" => 16.0,
    "#" => 16.0,
    "kg" => 35.274,
    "kgs" => 35.274,
    "kilogram" => 35.274,
    "gr" => 0.03527,
    "gram" => 0.03527,
    "grams" => 0.03527,
    "bushel" => 25.0 * 16.0,  # ~25 lbs, approximate for produce comparison
    "bu" => 25.0 * 16.0,
    "bush" => 25.0 * 16.0
  }.freeze

  # Volume conversions to fluid ounces
  VOLUME_TO_FL_OZ = {
    "fl oz" => 1.0,
    "floz" => 1.0,
    "fl" => 1.0,
    "pt" => 16.0,
    "pint" => 16.0,
    "pints" => 16.0,
    "qt" => 32.0,
    "quart" => 32.0,
    "quarts" => 32.0,
    "gal" => 128.0,
    "ga" => 128.0,
    "g" => 128.0,       # In food service pack sizes, "G" = gallons (grams use "GR")
    "gallon" => 128.0,
    "gallons" => 128.0,
    "ml" => 0.03381,
    "liter" => 33.814,
    "litre" => 33.814,
    "lt" => 33.814,
    "l" => 33.814
  }.freeze

  # Count-convertible units → normalized to "each"
  COUNT_TO_EACH = {
    "ea" => 1.0,
    "each" => 1.0,
    "ct" => 1.0,
    "count" => 1.0,
    "pc" => 1.0,
    "pcs" => 1.0,
    "piece" => 1.0,
    "pieces" => 1.0,
    "pk" => 1.0,
    "dz" => 12.0,
    "doz" => 12.0,
    "dozen" => 12.0
  }.freeze

  # Bushel conversion: ~25 lbs is a reasonable average for produce (peppers,
  # squash, greens). Approximate but enables cross-supplier price comparison.
  BUSHEL_TO_OZ = 25.0 * 16.0  # 400 oz

  # Produce/specialty units (not convertible to weight/volume/count — compared within their own category)
  PRODUCE_UNITS = {
    "bunch" => "bunch",
    "bunches" => "bunch",
    "bundle" => "bunch",
    "head" => "head",
    "heads" => "head",
    "stalk" => "stalk",
    "stalks" => "stalk",
    "flat" => "flat",
    "flats" => "flat",
    "pint" => "pint"  # pint of berries = count unit in produce
  }.freeze

  # Legacy set for unit_pattern matching (all recognized units)
  COUNT_UNITS = COUNT_TO_EACH.keys.to_set.freeze

  # Unit display names for normalized units
  DISPLAY_UNITS = {
    "oz" => "oz",
    "fl oz" => "fl oz",
    "each" => "ea",
    "bunch" => "bunch",
    "head" => "head",
    "stalk" => "stalk",
    "flat" => "flat"
  }.freeze

  class << self
    def parse(pack_size_str)
      return unparseable unless pack_size_str.present?

      text = pack_size_str.to_s.strip.downcase

      # Normalize: insert space between digits and letters ("32oz" → "32 oz", "550ct" → "550 ct")
      text = text.gsub(/(\d)(#{unit_pattern})\b/i, '\1 \2')

      # Strip duplicate trailing units: "4 3 lb lb" → "4 3 lb", "9 32 oz oz" → "9 32 oz"
      text = text.sub(/\b(lb|oz|ct|ea|gal|kg|cs|in|ml|dz|fl)\s+\1\b/, '\1')

      # Try each parsing strategy in order
      result = parse_mixed_fraction(text) ||
               parse_case_pack(text) ||
               parse_multiplied_pack(text) ||
               parse_simple_quantity(text) ||
               parse_pound_sign(text) ||
               parse_bare_unit(text)

      result || unparseable
    end

    # Convenience: calculate per-unit price
    def per_unit_price(price, pack_size_str)
      parsed = parse(pack_size_str)
      return nil unless parsed[:parseable] && parsed[:normalized_quantity] > 0 && price.present?

      (price.to_f / parsed[:normalized_quantity]).round(4)
    end

    # Returns the normalized quantity for a SINGLE piece within a case pack.
    # For "4x1 Gallon BC" → 128 fl oz (one gallon), "12x10.5 Oz BC" → 10.5 oz.
    # Returns nil for non-case-pack formats (e.g., "50 LB").
    def per_piece_normalized(pack_size_str)
      return nil unless pack_size_str.present?
      text = pack_size_str.to_s.strip.downcase

      # Match multiplied: "4x1 gallon", "12x10.5 oz"
      if text =~ /(\d+)\s*[x\/\-]\s*(\d+\.?\d*)\s*(#{unit_pattern})/i
        per_piece = $2.to_f
        unit = normalize_unit_str($3)
        result = normalize_to_base(per_piece, unit)
        return { quantity: result[:quantity].round(4), unit: result[:unit] } if result
      end

      # Match space-separated: "4 3 lb", "12 46 oz"
      if text =~ /\A\s*(\d+)\s+(\d+\.?\d*)\s*(#{unit_pattern})\s*\z/i
        count = $1.to_f
        per_piece = $2.to_f
        unit = normalize_unit_str($3)
        if count > 1 && count != per_piece
          result = normalize_to_base(per_piece, unit)
          return { quantity: result[:quantity].round(4), unit: result[:unit] } if result
        end
      end

      nil
    end

    # Check if two pack sizes are comparable (same normalized unit category)
    def comparable?(pack_size_a, pack_size_b)
      a = parse(pack_size_a)
      b = parse(pack_size_b)
      a[:parseable] && b[:parseable] && a[:normalized_unit] == b[:normalized_unit]
    end

    # Normalize a unit string to its canonical key (e.g., "LB" → "lb", "OZ" → "oz")
    # Used by SupplierListItem to convert price_unit from scrapers.
    def normalize_unit_key(unit_str)
      normalize_unit_str(unit_str.to_s)
    end

    # Calculate estimated total case price from a per-unit price.
    # Returns nil if the price isn't per-unit or can't be computed.
    #
    #   estimated_total(16.54, "lb", "12/6 LBA")  # => 1190.88
    #   estimated_total(0.50, "oz", "5 LB")        # => 40.0
    #   estimated_total(45.00, nil, "50 LB")        # => 45.0 (not per-unit, returns as-is)
    def estimated_total(price, price_unit_str, pack_size_str)
      return price unless price && price_unit_str.present?

      parsed = parse(pack_size_str)
      return price unless parsed[:parseable]

      unit_key = normalize_unit_key(price_unit_str)
      pack_qty = parsed[:quantity]
      pack_unit = parsed[:unit]

      if unit_key == pack_unit
        (price * pack_qty).round(2)
      else
        price_factor = WEIGHT_TO_OZ[unit_key] || VOLUME_TO_FL_OZ[unit_key] || COUNT_TO_EACH[unit_key]
        pack_factor = WEIGHT_TO_OZ[pack_unit] || VOLUME_TO_FL_OZ[pack_unit] || COUNT_TO_EACH[pack_unit]

        if price_factor && pack_factor
          pack_in_price_units = (pack_qty * pack_factor) / price_factor
          (price * pack_in_price_units).round(2)
        else
          price
        end
      end
    end

    # Format a per-unit price for display
    def format_per_unit(per_unit_price, normalized_unit)
      return nil unless per_unit_price && normalized_unit

      display_unit = DISPLAY_UNITS[normalized_unit] || normalized_unit

      if per_unit_price < 0.01
        "$#{'%.4f' % per_unit_price}/#{display_unit}"
      elsif per_unit_price < 1.0
        "$#{'%.2f' % per_unit_price}/#{display_unit}"
      else
        "$#{'%.2f' % per_unit_price}/#{display_unit}"
      end
    end

    private

    # Parses mixed fractions: "1-1/9 BUSH" → 1 + 1/9 = 1.111 bushels
    # Common in produce (bushel fractions): "1/2 BUSHEL", "1-1/9 BUSH"
    # Also handles simple fractions: "1/2 BUSHEL" → 0.5 bushels
    # Only triggers when there's a slash in the size (digit-digit/digit),
    # so normal case packs like "1-3#" or "12-6 OZ" are unaffected.
    def parse_mixed_fraction(text)
      # Mixed fraction: "1-1/9 BUSH", "2-1/2 BUSHEL" → whole + numerator/denominator
      # Only for bushel units — other units use digit/digit as case pack multipliers.
      if text =~ /(?:case|cs|box|bag|each|ea)?\s*[\-\s]*(\d+)\s*[\-]\s*(\d+)\s*\/\s*(\d+)\s*(bushel|bush|bu)\b/i
        whole = $1.to_f
        numerator = $2.to_f
        denominator = $3.to_f
        unit = normalize_unit_str($4)
        return nil if denominator == 0

        quantity = whole + (numerator / denominator)
        build_result(quantity, unit)

      # Simple fraction: "1/2 BUSHEL", "1/9 BUSH"
      # Only for bushel units — other units like "4/5 LB" are case packs (4×5), not fractions.
      elsif text =~ /(?:case|cs|box|bag|each|ea)?\s*[\-\s]*(\d+)\s*\/\s*(\d+)\s*(bushel|bush|bu)\b/i
        numerator = $1.to_f
        denominator = $2.to_f
        unit = normalize_unit_str($3)
        return nil if denominator == 0 || numerator >= denominator

        quantity = numerator / denominator
        build_result(quantity, unit)
      end
    end

    # Parses "Case - 12-2#" → 12 packs × 2 lb = 24 lb
    # Also: "Case 12/2 LB", "CS 6-5 LB", "12/2 LB", "4 3 LB" (space-separated)
    def parse_case_pack(text)
      # Pattern 1: separator-based — count -/x quantity unit
      if text =~ /(?:case|cs)?\s*[\-\s]*(\d+)\s*([\-\/x])\s*(\d+\.?\d*)\s*(#{unit_pattern})/i
        num1 = $1.to_f
        separator = $2
        num2 = $3.to_f
        unit = normalize_unit_str($4)

        # For count units (ct, ea, etc.), "80/88 CT" or "120-135 CT" is a size range
        # (apple/pear sizing), not a multiplier. Detect ranges by checking if both
        # numbers are close in magnitude (within 2x) and neither is 1.
        # "1-72 CT" is a multiplier (1 case × 72 ct), "80/88 CT" is a range.
        is_count_unit = COUNT_TO_EACH.key?(unit)
        is_range = is_count_unit && num1 > 1 && num2 > 1 &&
                   [num1 / num2, num2 / num1].max <= 2.0
        if is_range
          total = ((num1 + num2) / 2.0).round
          build_result(total.to_f, unit)
        else
          total = num1 * num2
          build_result(total, unit)
        end

      # Pattern 2: space-separated — "4 3 LB", "12 46 OZ", "6 5 LB"
      # Two numbers separated by space followed by a weight/volume unit.
      # The first number is the pack count, second is the per-unit size.
      # Only match when first number looks like a case count (small integer, typically 1-24).
      elsif text =~ /\A\s*(\d+)\s+(\d+\.?\d*)\s*(#{unit_pattern})\s*\z/i
        count = $1.to_f
        per_unit = $2.to_f
        unit = normalize_unit_str($3)

        # Treat as case pack when count differs from per_unit (avoids "50 50 LB"
        # misparse) and per_unit size is positive. Food service cases can have
        # large counts (36, 60, 100+).
        if count >= 1 && per_unit > 0 && count != per_unit
          total = count * per_unit
          build_result(total, unit)
        end
      end
    end

    # Parses "4x10 oz", "6 x 5 lb"
    def parse_multiplied_pack(text)
      if text =~ /(\d+)\s*x\s*(\d+\.?\d*)\s*(#{unit_pattern})/i
        count = $1.to_f
        per_unit = $2.to_f
        unit = normalize_unit_str($3)
        total = count * per_unit

        build_result(total, unit)
      end
    end

    # Parses "50 LB", "16 oz", "1 GAL", "5 lb case", "EA - 10 LB", "3/HEAD CS"
    def parse_simple_quantity(text)
      # Strip prefixes like "EA -", "CS -"
      cleaned = text.gsub(/^(ea|cs|case|bag|box|tray|bucket|jar)\s*[\-\s]+/i, "")

      if cleaned =~ /(\d+\.?\d*)[\/\s]*(#{unit_pattern})\b/i
        quantity = $1.to_f
        unit = normalize_unit_str($2)
        return nil if quantity <= 0

        build_result(quantity, unit)
      end
    end

    # Parses bare unit names with no quantity: "BUNCH", "DOZEN", "Each", "Pound"
    def parse_bare_unit(text)
      cleaned = text.gsub(/^(case|each|ea)\s*[\-\s]+/i, "").strip
      unit = normalize_unit_str(cleaned.split(/\s+/).first || "")

      if COUNT_TO_EACH.key?(unit) || PRODUCE_UNITS.key?(unit) || WEIGHT_TO_OZ.key?(unit) || VOLUME_TO_FL_OZ.key?(unit)
        build_result(1.0, unit)
      end
    end

    # Parses "40#" (pound sign notation)
    def parse_pound_sign(text)
      if text =~ /(\d+\.?\d*)\s*#/
        quantity = $1.to_f
        return nil if quantity <= 0

        build_result(quantity, "lb")
      end
    end

    def build_result(quantity, unit)
      normalized = normalize_to_base(quantity, unit)
      return nil unless normalized

      {
        quantity: quantity,
        unit: unit,
        normalized_quantity: normalized[:quantity].round(4),
        normalized_unit: normalized[:unit],
        parseable: true
      }
    end

    def normalize_to_base(quantity, unit)
      # Check weight
      if WEIGHT_TO_OZ.key?(unit)
        return { quantity: quantity * WEIGHT_TO_OZ[unit], unit: "oz" }
      end

      # Check volume
      if VOLUME_TO_FL_OZ.key?(unit)
        return { quantity: quantity * VOLUME_TO_FL_OZ[unit], unit: "fl oz" }
      end

      # Check count-convertible (ea, ct, dz, dozen → each)
      if COUNT_TO_EACH.key?(unit)
        return { quantity: quantity * COUNT_TO_EACH[unit], unit: "each" }
      end

      # Check produce/specialty units (comparable within their own category)
      if PRODUCE_UNITS.key?(unit)
        return { quantity: quantity, unit: PRODUCE_UNITS[unit] }
      end

      nil
    end

    def normalize_unit_str(str)
      s = str.to_s.strip.downcase
      s = "lb" if s == "lbs" || s == "pound" || s == "pounds"
      s = "oz" if s == "ounce" || s == "ounces"
      s = "gal" if s == "gallon" || s == "gallons" || s == "ga" || s == "g"
      s = "gr" if s == "gram" || s == "grams"
      s = "kg" if s == "kgs" || s == "kilogram"
      s = "each" if s == "ea" || s == "pc" || s == "pcs" || s == "piece" || s == "pieces"
      s = "ct" if s == "count"
      s = "dz" if s == "doz" || s == "dozen"
      s = "bunch" if s == "bunches" || s == "bundle"
      s = "head" if s == "heads"
      s = "stalk" if s == "stalks"
      s = "bushel" if s == "bu" || s == "bush"
      s = "flat" if s == "flats"
      s
    end

    def unit_pattern
      all_units = (WEIGHT_TO_OZ.keys + VOLUME_TO_FL_OZ.keys + COUNT_TO_EACH.keys + PRODUCE_UNITS.keys).uniq
      all_units.sort_by { |u| -u.length }.map { |u| Regexp.escape(u) }.join("|")
    end

    def unparseable
      { parseable: false }
    end
  end
end
