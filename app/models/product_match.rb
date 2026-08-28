class ProductMatch < ApplicationRecord
  # Associations
  belongs_to :aggregated_list
  belongs_to :off_list_added_by, class_name: "User", optional: true
  has_many :product_match_items, dependent: :destroy
  has_many :supplier_list_items, through: :product_match_items
  # teaser_matches.product_match_id is a real FK with no ON DELETE, so a match
  # can't be destroyed while its (display-only) teasers still point at it.
  has_many :teaser_matches, dependent: :destroy
  # Chef-chosen source of the canonical thumbnail (one of this match's own
  # suppliers' products). Nil → falls back to the primary item's product.
  belongs_to :canonical_image_supplier_product, class_name: 'SupplierProduct', optional: true
  # Sibling line already holding this line's product — set by CatalogSearchService
  # when it declines to fill a line that duplicates an existing one (typically
  # a split left over from a rotated order guide). Feeds the merge-review flow.
  belongs_to :possible_duplicate_of, class_name: 'ProductMatch', optional: true

  # Validations
  validates :match_status, inclusion: {
    in: %w[auto_matched confirmed rejected manual unmatched]
  }
  validate :canonical_image_belongs_to_match

  # Scopes
  scope :confirmed, -> { where(match_status: 'confirmed') }
  scope :auto_matched, -> { where(match_status: 'auto_matched') }
  scope :unmatched, -> { where(match_status: 'unmatched') }
  scope :needs_review, -> { where(match_status: %w[auto_matched unmatched]) }
  scope :flagged_duplicates, -> { where.not(possible_duplicate_of_id: nil) }
  scope :high_confidence, -> { where('confidence_score >= ?', 0.8) }
  scope :by_position, -> { order(:position) }

  # Status methods
  def confirmed?
    match_status == 'confirmed'
  end

  def auto_matched?
    match_status == 'auto_matched'
  end

  def unmatched?
    match_status == 'unmatched'
  end

  def needs_review?
    auto_matched? || unmatched?
  end

  # Confirm this match
  # --- Off-list additions (chef ordered something that wasn't curated) -------
  # Chefs can order any catalog product mid-shift. Those arrive with one
  # supplier and no price comparison, so owners/managers get told and the item
  # stays flagged until somebody actually looks at it.

  scope :off_list_added, -> { where.not(off_list_added_at: nil) }
  scope :needs_off_list_review, -> { off_list_added.where(reviewed_at: nil) }
  # Unreviewed off-list adds first (newest first), then normal list position
  scope :unreviewed_first, -> {
    order(Arel.sql("CASE WHEN off_list_added_at IS NOT NULL AND reviewed_at IS NULL THEN 0 ELSE 1 END"))
      .order(Arel.sql("off_list_added_at DESC NULLS LAST"))
      .order(:position)
  }

  def off_list_added?
    off_list_added_at.present?
  end

  def needs_off_list_review?
    off_list_added? && reviewed_at.nil?
  end

  def mark_reviewed!
    return unless needs_off_list_review?

    update!(reviewed_at: Time.current)
  end

  def confirm!
    # Confirming IS the review — an owner/manager has looked at this match.
    update!(match_status: 'confirmed', reviewed_at: reviewed_at || Time.current)
  end

  # Reject this match (AI got it wrong)
  def reject!
    update!(match_status: 'rejected')
  end

  # Can these suppliers' prices be ranked against each other?
  #
  # Only a shared pricing unit counts. We deliberately do NOT convert between
  # units here: an "each" price and an "oz" price cannot be ordered without
  # knowing the pack weight, and guessing produces a BEST badge that lies about
  # which supplier is actually cheaper.
  #
  # Takes the already-built price rows (see #prices_by_supplier) so the list
  # page can reuse the array it has rather than rebuild it per row. Returns
  # [verdict, group]:
  #   :exact        — two or more suppliers quote in the same unit; group is them
  #   :single       — fewer than two suppliers priced and in stock
  #   :incomparable — several suppliers, no two sharing a unit
  def self.compare_by_unit(in_stock_prices)
    with_per_unit = in_stock_prices.select { |p| p[:per_unit_price].to_f > 0 && p[:normalized_unit].present? }
    # "oz" and "fl oz" are close enough to rank together in food service.
    groups = with_per_unit.group_by { |p| p[:normalized_unit] == "fl oz" ? "oz" : p[:normalized_unit] }
    largest = groups.max_by { |_unit, items| items.size }&.last || []

    return [:exact, largest] if largest.size >= 2
    return [:single, []] if in_stock_prices.size < 2

    [:incomparable, []]
  end

  # This match's comparison verdict, for callers that don't already hold the
  # price rows (single-record Turbo re-renders).
  #
  # DEPRECATED for display. This is the same-unit-only reading and it cannot
  # see the estimated conversions #comparable_group makes, so a page driven by
  # it disagrees with the order builder about who is cheapest. Use
  # #comparison_verdict. Kept because .compare_by_unit is still the honest
  # answer to "do two suppliers literally share a unit".
  def unit_comparison
    in_stock = prices_by_supplier.select { |p| p[:price].to_f > 0 && p[:in_stock] }
    self.class.compare_by_unit(in_stock).first
  end

  # The single comparison verdict every screen renders from, so the matched
  # list, the order builder and the match modal cannot disagree about who is
  # cheapest on the same line.
  #
  #   :single       — fewer than two suppliers priced and in stock
  #   :exact        — ranked on units the suppliers themselves quoted
  #   :estimated    — ranked, but only because we converted a count or a bushel
  #                   with a weight nobody stated. Earns a marked BEST, never
  #                   a clean one, and offers the chef a Set Weight control.
  #   :incomparable — no two suppliers can be ranked at all
  def comparison_verdict
    return @comparison_verdict if defined?(@comparison_verdict)

    in_stock = prices_by_supplier.select { |p| p[:price].to_f > 0 && p[:in_stock] }
    @comparison_verdict =
      if in_stock.size < 2
        :single
      elsif comparable_group.size < 2
        :incomparable
      elsif comparable_group.any? { |p| p[:comparison_estimated] }
        :estimated
      else
        :exact
      end
  end

  # What a routing decision on this line rests on, recorded against the order
  # item so the choice stays auditable after the fact.
  #
  #   "exact"      — the suppliers' own shared unit settled it
  #   "estimated"  — settled by a pack weight nobody stated
  #   "single"     — only one supplier carries it; nothing was compared
  #   "case_total" — no shared basis at all, so the lowest case total won,
  #                  which knows nothing about how much is in the box
  def routing_basis
    case comparison_verdict
    when :exact then "exact"
    when :estimated then "estimated"
    when :single then "single"
    else "case_total"
    end
  end

  # True when this supplier's price only joins the comparison through an
  # estimate — the cell that should offer Set Weight.
  def estimated_basis_for?(supplier)
    entry = comparable_group.find { |p| p[:supplier] == supplier }
    entry.present? && entry[:comparison_estimated].present?
  end

  # Everything a list row needs to render its price story. Built here rather
  # than inline in each controller: three separate copies of this had already
  # drifted apart, and only one of them consulted comparison_per_oz.
  def price_summary
    cheapest = cheapest_supplier
    priciest = most_expensive_supplier

    {
      cheapest_supplier: cheapest&.dig(:supplier),
      most_expensive_supplier: priciest&.dig(:supplier),
      spread: price_spread,
      comparison: comparison_verdict,
      compared_supplier_ids: comparable_group.map { |p| p[:supplier].id }
    }
  end

  # Price comparison across matched items (memoized — safe to call repeatedly).
  # Uses supplier_list_item.price (from the order guide) as the primary source —
  # this is the case/pack price the user actually pays when ordering.
  # Falls back to supplier_product.current_price only when no SLI price exists.
  def prices_by_supplier
    @prices_by_supplier ||= product_match_items.map do |pmi|
      item = pmi.supplier_list_item
      sp = item.supplier_product
      {
        supplier: pmi.supplier,
        item: item,
        price: item.price || sp&.current_price,
        # Case-equivalent price: converts per-unit prices (explicit or inferred
        # catch-weight) to the full case cost. Use this for totals/selection —
        # raw :price is $2.00/lb for catch-weight pork, not the ~$100 case.
        estimated_price: item.estimated_total_price || item.price || sp&.current_price,
        pack_size: item.pack_size || sp&.pack_size,
        per_unit_price: item.per_unit_price,
        normalized_unit: item.normalized_unit,
        formatted_per_unit: item.formatted_per_unit_price,
        comparison_per_oz: item.comparison_per_oz,
        in_stock: sp ? sp.in_stock : item.in_stock
      }
    end
  end

  # Find the group of items that can be compared apples-to-apples, tagging
  # each entry with :comparison_metric (the value cheapest/most-expensive
  # rank by) and :comparison_estimated.
  #
  # When suppliers MIX units on the same product (48 CT limes vs a 10 LB
  # case), count/pint produce converts to estimated $/oz via
  # ProduceWeightEstimator so every supplier competes — the old behavior
  # silently dropped whichever unit group was smaller. When units are
  # homogeneous (or no estimate exists), same-unit grouping applies as
  # before: "oz" and "fl oz" merge (~1:1 in food service), other units
  # (each, bunch, head…) compare only within their own kind.
  def comparable_group
    return @comparable_group if defined?(@comparable_group)

    items = prices_by_supplier.select { |p| p[:price].present? && p[:price] > 0 && p[:in_stock] }
    units = items.map { |p| p[:normalized_unit] == "fl oz" ? "oz" : p[:normalized_unit] }.compact.uniq
    convertible = items.select { |p| p[:comparison_per_oz].present? }

    @comparable_group =
      if units.size > 1 && convertible.size >= 2
        convertible.each do |p|
          p[:comparison_metric] = p[:comparison_per_oz][:value]
          p[:comparison_estimated] = p[:comparison_per_oz][:estimated]
        end
        convertible
      else
        grouped = items.select { |p| p[:per_unit_price].present? && p[:per_unit_price] > 0 && p[:normalized_unit].present? }
        groups = grouped.group_by { |p| p[:normalized_unit] == "fl oz" ? "oz" : p[:normalized_unit] }
        best = groups.max_by { |_unit, g| g.size }&.last || []
        best.each do |p|
          p[:comparison_metric] = p[:per_unit_price]
          p[:comparison_estimated] = false
        end
        best
      end
  end

  # Display per-unit string for one supplier's item, using the estimated
  # $/oz conversion when this match compares mixed units ("~$0.06/oz est"),
  # otherwise the item's own exact per-unit string.
  def display_per_unit_for(item)
    entry = comparable_group.find { |p| p[:item] == item }
    if entry && entry[:comparison_estimated]
      "~#{UnitParser.format_per_unit(entry[:comparison_metric], 'oz')} est"
    else
      item.formatted_per_unit_price
    end
  end

  # Are per-unit prices comparable across suppliers? (at least 2 items share the same unit)
  def per_unit_comparable?
    return @per_unit_comparable if defined?(@per_unit_comparable)
    @per_unit_comparable = comparable_group.size >= 2
  end

  def cheapest_supplier
    @cheapest_supplier ||= begin
      if per_unit_comparable?
        comparable_group.min_by { |p| p[:comparison_metric] || p[:per_unit_price] }
      else
        prices = prices_by_supplier.select { |p| p[:price].present? && p[:price] > 0 && p[:in_stock] }
        # Compare case-equivalents — a raw per-lb price would always "win"
        prices.min_by { |p| p[:estimated_price] || p[:price] } if prices.any?
      end
    end
  end

  def most_expensive_supplier
    @most_expensive_supplier ||= begin
      if per_unit_comparable?
        comparable_group.max_by { |p| p[:comparison_metric] || p[:per_unit_price] }
      else
        prices = prices_by_supplier.select { |p| p[:price].present? && p[:price] > 0 && p[:in_stock] }
        # Compare case-equivalents — a raw per-lb price would always "lose"
        prices.max_by { |p| p[:estimated_price] || p[:price] } if prices.any?
      end
    end
  end

  def price_spread
    return @price_spread if defined?(@price_spread)
    @price_spread = if per_unit_comparable?
      comparable_group.map { |p| p[:per_unit_price] }.max - comparable_group.map { |p| p[:per_unit_price] }.min
    else
      prices = prices_by_supplier.select { |p| p[:price].present? }
      if prices.size >= 2
        prices.map { |p| p[:price] }.max - prices.map { |p| p[:price] }.min
      end
    end
  end

  # Get the item for a specific supplier — uses in-memory detect (not find_by)
  # to avoid N+1 queries when product_match_items are already preloaded.
  def item_for_supplier(supplier)
    product_match_items.detect { |pmi| pmi.supplier_id == supplier.id }&.supplier_list_item
  end

  # Display name
  def display_name
    canonical_name.presence || primary_item&.name || 'Unnamed Product'
  end

  # The SupplierProduct whose mirrored thumbnail represents this match.
  # Explicit chef choice wins; otherwise fall back to the primary item's product.
  # Views render it via ProductImagesHelper#product_thumb_url.
  def canonical_image_source
    canonical_image_supplier_product || primary_item&.supplier_product
  end

  # SupplierProducts available to choose the canonical image from (this match's
  # own matched suppliers), as [SupplierProduct] — used by the modal picker.
  def canonical_image_choices
    product_match_items.filter_map { |pmi| pmi.supplier_list_item&.supplier_product }.uniq
  end

  private

  # Uses detect on the preloaded collection instead of find_by (which always hits DB)
  def primary_item
    product_match_items.detect { |pmi| pmi.is_primary }&.supplier_list_item
  end

  # The canonical image must come from one of this match's own matched suppliers.
  def canonical_image_belongs_to_match
    return if canonical_image_supplier_product_id.blank?
    return if canonical_image_choices.map(&:id).include?(canonical_image_supplier_product_id)

    errors.add(:canonical_image_supplier_product_id, 'must be one of this match\'s supplier products')
  end
end
