# Shared cross-supplier comparison basis for SupplierListItem and
# SupplierProduct: price per ounce, exact for weight/volume packs and
# ESTIMATED (via ProduceWeightEstimator) for count-based and pint-basket
# produce, so "48 CT" limes can compare against a "10 LB" case.
#
# Including models must provide: comparison_price, comparison_name,
# parsed_pack_size, normalized_unit, per_unit_price, pack_size.
module UnitComparable
  # Returns { value:, estimated: } or nil when no sound conversion exists
  # (unknown produce, bunch/head/stalk packs).
  def comparison_per_oz
    price = comparison_price
    return nil unless price.present? && price.positive?

    pu = per_unit_price
    case normalized_unit
    when "oz"
      pu && pu.positive? ? { value: pu, estimated: false } : nil
    when "fl oz"
      basket_lbs = ProduceWeightEstimator.pint_basket_lbs(comparison_name)
      if basket_lbs && pack_size.to_s.match?(/\b(pt|pint)s?\b/i)
        # A pint of cherry tomatoes is a basket (a piece), not 16 fl oz of
        # liquid: "12 PT" = 12 baskets ≈ 12 × basket_lbs.
        baskets = parsed_pack_size[:normalized_quantity] / 16.0
        return nil unless baskets.positive?
        { value: (price / (baskets * basket_lbs * 16.0)).round(4), estimated: true }
      else
        # Volume ≈ weight oz is the existing food-service comparison convention
        pu && pu.positive? ? { value: pu, estimated: false } : nil
      end
    when "each"
      # For basket produce, a "count" is a basket (12 CT cherry tomatoes =
      # 12 pint baskets), so the basket weight is the right divisor — the
      # same basis the pint-pack branch uses.
      piece_lbs = ProduceWeightEstimator.pint_basket_lbs(comparison_name) ||
                  ProduceWeightEstimator.piece_lbs(comparison_name)
      return nil unless piece_lbs && pu && pu.positive?
      { value: (pu / (piece_lbs * 16.0)).round(4), estimated: true }
    end
  end

  # Display string for the comparison basis: "~$0.06/oz est" for estimated
  # conversions, the normal per-unit string otherwise.
  def formatted_comparison_per_oz
    c = comparison_per_oz
    return formatted_per_unit_price unless c

    formatted = UnitParser.format_per_unit(c[:value], "oz")
    c[:estimated] ? "~#{formatted} est" : formatted
  end
end
