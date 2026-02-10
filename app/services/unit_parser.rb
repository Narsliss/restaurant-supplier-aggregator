# Parses free-text pack_size strings from supplier products into structured
# quantities with normalized units for apples-to-apples price comparison.
#
# Examples:
#   UnitParser.parse("50 LB")        => { quantity: 50, unit: "lb", normalized_quantity: 800, normalized_unit: "oz", parseable: true }
#   UnitParser.parse("16 oz")        => { quantity: 16, unit: "oz", normalized_quantity: 16, normalized_unit: "oz", parseable: true }
#   UnitParser.parse("1 GAL")        => { quantity: 1, unit: "gal", normalized_quantity: 128, normalized_unit: "fl oz", parseable: true }
#   UnitParser.parse("4x10 oz")      => { quantity: 40, unit: "oz", normalized_quantity: 40, normalized_unit: "oz", parseable: true }
#   UnitParser.parse("Case - 12-2#") => { quantity: 24, unit: "lb", normalized_quantity: 384, normalized_unit: "oz", parseable: true }
#
class UnitParser
  # Weight conversions to ounces
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
    "g" => 0.03527,
    "gr" => 0.03527,
    "gram" => 0.03527,
    "grams" => 0.03527
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
    "gallon" => 128.0,
    "gallons" => 128.0,
    "ml" => 0.03381,
    "liter" => 33.814,
    "litre" => 33.814,
    "l" => 33.814
  }.freeze

  # Count units (no conversion needed)
  COUNT_UNITS = %w[ea each ct count pc pcs piece pieces pk].to_set.freeze

  # Unit display names for normalized units
  DISPLAY_UNITS = {
    "oz" => "oz",
    "fl oz" => "fl oz",
    "each" => "ea"
  }.freeze

  class << self
    def parse(pack_size_str)
      return unparseable unless pack_size_str.present?

      text = pack_size_str.to_s.strip.downcase

      # Try each parsing strategy in order
      result = parse_case_pack(text) ||
               parse_multiplied_pack(text) ||
               parse_simple_quantity(text) ||
               parse_pound_sign(text)

      result || unparseable
    end

    # Convenience: calculate per-unit price
    def per_unit_price(price, pack_size_str)
      parsed = parse(pack_size_str)
      return nil unless parsed[:parseable] && parsed[:normalized_quantity] > 0 && price.present?

      (price.to_f / parsed[:normalized_quantity]).round(4)
    end

    # Check if two pack sizes are comparable (same normalized unit category)
    def comparable?(pack_size_a, pack_size_b)
      a = parse(pack_size_a)
      b = parse(pack_size_b)
      a[:parseable] && b[:parseable] && a[:normalized_unit] == b[:normalized_unit]
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

    # Parses "Case - 12-2#" → 12 packs × 2 lb = 24 lb
    # Also: "Case 12/2 LB", "CS 6-5 LB", "12/2 LB"
    def parse_case_pack(text)
      # Pattern: case/cs prefix (optional) + count - or / quantity unit
      if text =~ /(?:case|cs)?\s*[\-\s]*(\d+)\s*[\-\/x]\s*(\d+\.?\d*)\s*(#{unit_pattern})/i
        count = $1.to_f
        per_unit = $2.to_f
        unit = normalize_unit_str($3)
        total = count * per_unit

        build_result(total, unit)
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

    # Parses "50 LB", "16 oz", "1 GAL", "5 lb case", "EA - 10 LB"
    def parse_simple_quantity(text)
      # Strip prefixes like "EA -", "CS -"
      cleaned = text.gsub(/^(ea|cs|case|bag|box|tray|bucket|jar)\s*[\-\s]+/i, "")

      if cleaned =~ /(\d+\.?\d*)\s*(#{unit_pattern})\b/i
        quantity = $1.to_f
        unit = normalize_unit_str($2)
        return nil if quantity <= 0

        build_result(quantity, unit)
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

      # Check count
      if COUNT_UNITS.include?(unit)
        return { quantity: quantity, unit: "each" }
      end

      nil
    end

    def normalize_unit_str(str)
      s = str.to_s.strip.downcase
      s = "lb" if s == "lbs" || s == "pound" || s == "pounds"
      s = "oz" if s == "ounce" || s == "ounces"
      s = "gal" if s == "gallon" || s == "gallons" || s == "ga"
      s = "g" if s == "gr" || s == "gram" || s == "grams"
      s = "kg" if s == "kgs" || s == "kilogram"
      s = "each" if s == "ea" || s == "pc" || s == "pcs" || s == "piece" || s == "pieces"
      s = "ct" if s == "count"
      s
    end

    def unit_pattern
      all_units = (WEIGHT_TO_OZ.keys + VOLUME_TO_FL_OZ.keys + COUNT_UNITS.to_a).uniq
      all_units.sort_by { |u| -u.length }.map { |u| Regexp.escape(u) }.join("|")
    end

    def unparseable
      { parseable: false }
    end
  end
end
