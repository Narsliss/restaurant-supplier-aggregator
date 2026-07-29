# Estimates average piece weights for produce sold by count, enabling
# cross-supplier price comparison when one supplier sells "48 CT" limes and
# another sells a "10 LB" case. Weights are industry-standard case math
# (70-ct baker potatoes ship in 50 lb cartons → ~0.7 lb each).
#
# Conversions built on these estimates are ESTIMATES — display them with a
# "~" marker. Returns nil for anything it doesn't confidently recognize;
# callers fall back to same-unit-only comparison.
class ProduceWeightEstimator
  # Pint-basket produce: a "PT" here is a physical basket (a piece), not
  # 16 fl oz of liquid. Approximate net weight per basket in lbs.
  PINT_BASKET_LBS = {
    "cherry tomato" => 0.75,
    "grape tomato" => 0.75,
    "currant tomato" => 0.75,
    "heirloom cherry" => 0.75,
    "strawberr" => 1.0,
    "blueberr" => 0.75,
    "raspberr" => 0.75,
    "blackberr" => 0.75
  }.freeze

  # Average piece weight in lbs. Multi-word keys are checked before
  # single-word keys so "sweet potato" wins over "potato".
  PIECE_LBS = {
    "sweet potato" => 0.85,
    "bell pepper" => 0.45,
    "red pepper" => 0.45,
    "green pepper" => 0.45,
    "yellow pepper" => 0.45,
    "orange pepper" => 0.45,
    "head lettuce" => 1.5,
    "potato" => 0.7,
    "lime" => 0.2,
    "lemon" => 0.28,
    "orange" => 0.35,
    "avocado" => 0.5,
    "cucumber" => 0.65,
    "zucchini" => 0.55,
    "squash" => 0.55,
    "eggplant" => 1.1,
    "onion" => 0.55,
    "tomato" => 0.55,
    "cabbage" => 2.75,
    "cauliflower" => 1.75,
    "iceberg" => 1.5,
    "romaine" => 1.25,
    "celery" => 2.0,
    "pineapple" => 3.5,
    "cantaloupe" => 3.0,
    "honeydew" => 4.5,
    "watermelon" => 15.0,
    "garlic" => 0.15,
    "apple" => 0.35,
    "pear" => 0.4,
    "mango" => 0.6,
    "corn" => 0.8
  }.freeze

  class << self
    # Average weight of one piece, in lbs, or nil if unrecognized.
    def piece_lbs(name)
      lookup(PIECE_LBS, name)
    end

    # Net weight of one pint basket, in lbs, or nil if this product isn't
    # pint-basket produce.
    def pint_basket_lbs(name)
      lookup(PINT_BASKET_LBS, name)
    end

    private

    def lookup(table, name)
      return nil if name.blank?

      text = name.to_s.downcase
      # Supplier names word-shuffle ("Tomato Cherry Heirloom" vs "CHERRY
      # TOMATOES"), so a key matches when ALL its words appear anywhere in
      # the name. Most-specific keys first (word count, then length) so
      # "sweet potato" beats "potato".
      table.keys.sort_by { |k| [-k.split.size, -k.length] }.each do |key|
        return table[key] if key.split.all? { |word| text.include?(word) }
      end
      nil
    end
  end
end
