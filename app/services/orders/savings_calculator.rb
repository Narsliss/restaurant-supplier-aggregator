module Orders
  # One definition of savings, for one order line.
  #
  # Every savings figure in the product used to be computed by whichever screen
  # was drawing it, against whichever benchmark that screen happened to pick.
  # The dashboard tile compared against the dearest peer at order time, the
  # Best Deals table against a raw MAX(current_price) with no unit conversion at
  # all, and missed-savings against the cheapest peer. None of the three
  # reconciled, and two of them were wrong.
  #
  # This is the single answer. Given an order line and the supplier products
  # matched to it, it returns what the chef beat the market by and what they
  # left behind — or says plainly that the line cannot be compared.
  #
  #   result = Orders::SavingsCalculator.call(order_item, peers)
  #   result.comparable?  # => true
  #   result.realized     # => 41.90
  #   result.missed       # => 0.0
  #
  # THE BENCHMARK IS THE DEAREST COMPARABLE PEER
  #
  # Realized and missed then split one fixed quantity: the market spread on that
  # line. realized + missed always equals (dearest - cheapest), so the chef's
  # choice only decides how the spread is allocated between money captured and
  # money left behind. A middle pick fires both.
  #
  # WHY THE PACK BAND IS NOT OPTIONAL
  #
  # The dearest peer is only meaningful among products the chef could actually
  # have bought instead. Alfios buys commodity 80% unsalted butter prints in a
  # 36 lb case at $2.50/lb. Name matching correctly surfaces a single retail
  # pound at $5.00/lb and a 12 lb case of Vermont Creamery cultured butter at
  # $8.75/lb — both genuinely unsalted butter, so no similarity threshold
  # separates them. Unbanded, that line claimed $449.70 of savings on a $180
  # purchase. Banded, the survivors are $90.32 and $94.00, and the line reads
  # as roughly $8 — the truth, which is that they buy butter at market.
  #
  # KNOWN LIMITATION
  #
  # A premium variant that happens to ship in a comparable pack still lifts the
  # benchmark. The 6x spread gate is the only backstop, and it is a coarse one.
  # See the spec that documents this deliberately.
  class SavingsCalculator
    # A peer pack must be within this multiple of the ordered pack to count as
    # an alternative the chef could actually have bought instead.
    PACK_BAND_MIN = 0.6
    PACK_BAND_MAX = 1.67

    # Past this, the cheapest and dearest "same" product are not the same
    # product. Treat the whole line as unmatched rather than claim a number.
    MAX_SPREAD_RATIO = 6.0

    # Paying below every peer is arithmetically possible (negotiated pricing),
    # but paying far below all of them means the match or the unit basis is
    # wrong. Allow a real discount, reject a fantasy one.
    MIN_PAID_RATIO = 0.5

    # Where a supplier states a weight or a volume we trust it absolutely, and a
    # chef weight is never consulted. UnitOverride exists for the packs quoted
    # in bushels, sheets and counts, where nobody said what is in the box.
    STATED_UNITS = ["oz", "fl oz"].freeze

    Result = Struct.new(
      :realized, :missed, :benchmark_rate, :best_rate, :paid_rate,
      :units_per_case, :peer_count, :reason, :best_peer, :benchmark_peer,
      keyword_init: true
    ) do
      # What the cheapest alternative would have cost for the quantity bought.
      def best_equivalent_cost
        return nil unless best_rate && units_per_case

        (best_rate * units_per_case).round(2)
      end

      def comparable? = reason.nil?
      def total_spread = realized.to_f + missed.to_f
    end

    def self.call(order_item, peers, overrides: {})
      new(order_item, peers, overrides: overrides).call
    end

    def initialize(order_item, peers, overrides: {})
      @item = order_item
      @peers = Array(peers)
      @overrides = overrides || {}
    end

    def call
      return incomparable(:no_supplier_product) unless product
      return incomparable(:unparseable_pack) unless units_per_case&.positive?
      return incomparable(:no_paid_price) unless paid_rate&.positive?
      return incomparable(:no_quantity) unless quantity.positive?

      priced = comparable_peers
      return incomparable(:no_comparable_peer) if priced.empty?

      rates = priced.map(&:last)
      best = (rates + [paid_rate]).min
      return incomparable(:implausible_spread) if rates.max / best > MAX_SPREAD_RATIO
      return incomparable(:paid_below_market) if paid_rate < rates.min * MIN_PAID_RATIO

      benchmark = rates.max
      cheapest_peer = priced.min_by(&:last)
      dearest_peer = priced.max_by(&:last)
      Result.new(
        realized: scale(benchmark - paid_rate),
        missed: scale(paid_rate - best),
        benchmark_rate: benchmark,
        best_rate: best,
        paid_rate: paid_rate,
        units_per_case: units_per_case,
        peer_count: rates.size,
        reason: nil,
        best_peer: cheapest_peer&.first,
        benchmark_peer: dearest_peer&.first
      )
    end

    private

    attr_reader :item, :peers, :overrides

    # A weight the chef supplied for a pack the supplier never described, in oz.
    #
    # UnitOverride feeds comparison and nothing else by design, so this is
    # exactly the right consumer: it lets a bushel or a count of sheets be
    # compared without touching the raw price that ordering reads. A weight is
    # ignored once the supplier changes the pack out from under it.
    def chef_weight_oz(product)
      override = overrides[[product.supplier_id, product.supplier_sku]]
      return nil if override.nil?
      return nil if override.stale_against?(product.pack_size)

      oz = override.total_oz_for(product.pack_size)
      oz if oz.to_f.positive?
    end

    # Size and unit to compare this product on: the chef's weight when they set
    # one, otherwise whatever the pack itself says.
    def size_and_unit(product)
      parsed = product.parsed_pack_size
      stated = parsed[:parseable] && STATED_UNITS.include?(parsed[:normalized_unit])

      unless stated
        oz = chef_weight_oz(product)
        return [oz, "oz"] if oz
      end

      return [nil, nil] unless parsed[:parseable]

      [parsed[:normalized_quantity].to_f, parsed[:normalized_unit]]
    end

    def product = @product ||= item.supplier_product

    # Normalized units (oz, fl oz, each) in one of the cases the chef buys.
    def units_per_case
      return @units_per_case if defined?(@units_per_case)

      size, unit = size_and_unit(product)
      @base_unit = unit
      @units_per_case = size if size.to_f.positive?
    end

    def base_unit
      units_per_case
      @base_unit
    end

    # What they actually paid, per normalized unit. The invoice, not the
    # catalog — a negotiated price is the real one.
    def paid_rate
      return @paid_rate if defined?(@paid_rate)

      @paid_rate = units_per_case ? item.unit_price.to_f / units_per_case : nil
    end

    def quantity = item.quantity.to_f

    # [product, rate] for every peer that survives the unit, pack and price
    # checks. Kept as pairs so callers can name the supplier behind a figure --
    # a savings number nobody can trace to a supplier is not much use.
    def comparable_peers
      peers.filter_map do |peer|
        next if peer.id == product.id
        next if peer.supplier_id == product.supplier_id
        peer_size, peer_unit = size_and_unit(peer)
        next unless peer_unit == base_unit
        next unless peer_size.to_f.positive?
        next unless within_pack_band?(peer_size)

        rate = peer_rate(peer, peer_size)
        [peer, rate] if rate&.positive?
      end
    end

    def within_pack_band?(peer_size)
      peer_size >= units_per_case * PACK_BAND_MIN && peer_size <= units_per_case * PACK_BAND_MAX
    end

    # A per-weight quote converts against its own unit; anything else is spread
    # across the pack, using the chef's weight when they supplied one.
    def peer_rate(peer, peer_size)
      unit = peer.effective_price_unit
      if unit.present?
        key = UnitParser.normalize_unit_key(unit)
        factor = UnitParser::WEIGHT_TO_OZ[key] || UnitParser::VOLUME_TO_FL_OZ[key]
        return peer.current_price.to_f / factor if factor.to_f.positive?
      end

      peer.current_price.to_f / peer_size
    end

    # Dollars for the whole line, from a per-unit difference.
    def scale(rate_delta)
      return 0.0 if rate_delta <= 0

      (rate_delta * units_per_case * quantity).round(2)
    end

    def incomparable(reason)
      Result.new(realized: 0.0, missed: 0.0, peer_count: 0, reason: reason)
    end
  end
end
