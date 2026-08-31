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

    Result = Struct.new(
      :realized, :missed, :benchmark_rate, :best_rate, :paid_rate,
      :units_per_case, :peer_count, :reason,
      keyword_init: true
    ) do
      def comparable? = reason.nil?
      def total_spread = realized.to_f + missed.to_f
    end

    def self.call(order_item, peers)
      new(order_item, peers).call
    end

    def initialize(order_item, peers)
      @item = order_item
      @peers = Array(peers)
    end

    def call
      return incomparable(:no_supplier_product) unless product
      return incomparable(:unparseable_pack) unless units_per_case&.positive?
      return incomparable(:no_paid_price) unless paid_rate&.positive?
      return incomparable(:no_quantity) unless quantity.positive?

      rates = comparable_peer_rates
      return incomparable(:no_comparable_peer) if rates.empty?

      best = (rates + [paid_rate]).min
      return incomparable(:implausible_spread) if rates.max / best > MAX_SPREAD_RATIO
      return incomparable(:paid_below_market) if paid_rate < best_of(rates) * MIN_PAID_RATIO

      benchmark = rates.max
      Result.new(
        realized: scale(benchmark - paid_rate),
        missed: scale(paid_rate - best),
        benchmark_rate: benchmark,
        best_rate: best,
        paid_rate: paid_rate,
        units_per_case: units_per_case,
        peer_count: rates.size,
        reason: nil
      )
    end

    private

    attr_reader :item, :peers

    def product = @product ||= item.supplier_product

    # Normalized units (oz, fl oz, each) in one of the cases the chef buys.
    def units_per_case
      return @units_per_case if defined?(@units_per_case)

      parsed = product.parsed_pack_size
      @units_per_case =
        if parsed[:parseable] && parsed[:normalized_quantity].to_f.positive?
          parsed[:normalized_quantity].to_f
        end
    end

    # What they actually paid, per normalized unit. The invoice, not the
    # catalog — a negotiated price is the real one.
    def paid_rate
      return @paid_rate if defined?(@paid_rate)

      @paid_rate = units_per_case ? item.unit_price.to_f / units_per_case : nil
    end

    def quantity = item.quantity.to_f

    def comparable_peer_rates
      peers.filter_map do |peer|
        next if peer.id == product.id
        next if peer.supplier_id == product.supplier_id
        next unless peer.normalized_unit == product.normalized_unit
        next unless within_pack_band?(peer)

        rate = peer.comparison_rate
        rate if rate&.positive?
      end
    end

    def within_pack_band?(peer)
      parsed = peer.parsed_pack_size
      return false unless parsed[:parseable]

      qty = parsed[:normalized_quantity].to_f
      return false unless qty.positive?

      qty >= units_per_case * PACK_BAND_MIN && qty <= units_per_case * PACK_BAND_MAX
    end

    # Dollars for the whole line, from a per-unit difference.
    def scale(rate_delta)
      return 0.0 if rate_delta <= 0

      (rate_delta * units_per_case * quantity).round(2)
    end

    def best_of(rates) = rates.min

    def incomparable(reason)
      Result.new(realized: 0.0, missed: 0.0, peer_count: 0, reason: reason)
    end
  end
end
