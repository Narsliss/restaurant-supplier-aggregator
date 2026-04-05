module PriceClassifiers
  class PremiereProduceOne < Base
    private

    def skip_inference?
      return true if super

      # "Case - 75# AVG" — the "Case -" prefix means case-priced.
      return true if pack_size =~ /\ACase\s*-/i

      # PPO "EACH - 1-N#" items: the price MIGHT be per-container (case)
      # or per-lb — PPO uses the same format for both. Use a price
      # reasonableness check: if implied $/lb ≥ $2, assume case pricing
      # (the price IS for the whole unit). If implied $/lb < $2, the
      # item is likely priced per-lb (too cheap to be a case price for
      # most food products).
      if item.price_unit.present? && UnitParser.normalize_unit_key(item.price_unit) == "each"
        parsed = UnitParser.parse(pack_size)
        if parsed[:parseable] && parsed[:unit] == "#" && parsed[:quantity] > 0 && item.price.present?
          implied_per_lb = item.price / parsed[:quantity]
          return implied_per_lb >= 2.0
        end

        # Non-pound EACH items (QT, KG, etc.) are genuine per-each pricing
        return true
      end

      false
    end

    # PPO "EACH - 1-N#" items where skip_inference? allowed inference
    # (implied $/lb < $2) — these are per-lb priced.
    def detect_variable_weight_unit
      # Check base patterns first (LB+, #AVG, etc.)
      base_result = super
      return base_result if base_result

      # PPO-specific: EACH items with # weight that passed the price
      # reasonableness check are per-lb.
      if item.price_unit.present? && UnitParser.normalize_unit_key(item.price_unit) == "each"
        return "lb" if pack_size =~ /\d+\s*(?:#|lb\b)/i
      end

      nil
    end
  end
end
