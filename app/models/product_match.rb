class ProductMatch < ApplicationRecord
  # Associations
  belongs_to :aggregated_list
  has_many :product_match_items, dependent: :destroy
  has_many :supplier_list_items, through: :product_match_items

  # Validations
  validates :match_status, inclusion: {
    in: %w[auto_matched confirmed rejected manual unmatched]
  }

  # Scopes
  scope :confirmed, -> { where(match_status: 'confirmed') }
  scope :auto_matched, -> { where(match_status: 'auto_matched') }
  scope :unmatched, -> { where(match_status: 'unmatched') }
  scope :needs_review, -> { where(match_status: %w[auto_matched unmatched]) }
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
  def confirm!
    update!(match_status: 'confirmed')
  end

  # Reject this match (AI got it wrong)
  def reject!
    update!(match_status: 'rejected')
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
        pack_size: item.pack_size || sp&.pack_size,
        per_unit_price: item.per_unit_price,
        normalized_unit: item.normalized_unit,
        formatted_per_unit: item.formatted_per_unit_price,
        in_stock: sp ? sp.in_stock : item.in_stock
      }
    end
  end

  # Find the largest group of items that share the same normalized unit
  # and have per-unit prices — these can be compared apples-to-apples.
  # Treats "oz" (weight) and "fl oz" (volume) as equivalent since they're
  # close enough for price comparison in food service (~1:1 for most items).
  def comparable_group
    return @comparable_group if defined?(@comparable_group)
    items = prices_by_supplier.select { |p| p[:price].present? && p[:price] > 0 && p[:in_stock] && p[:per_unit_price].present? && p[:per_unit_price] > 0 && p[:normalized_unit].present? }
    groups = items.group_by { |p| p[:normalized_unit] == "fl oz" ? "oz" : p[:normalized_unit] }
    @comparable_group = groups.max_by { |_unit, g| g.size }&.last || []
  end

  # Are per-unit prices comparable across suppliers? (at least 2 items share the same unit)
  def per_unit_comparable?
    return @per_unit_comparable if defined?(@per_unit_comparable)
    @per_unit_comparable = comparable_group.size >= 2
  end

  def cheapest_supplier
    @cheapest_supplier ||= begin
      if per_unit_comparable?
        comparable_group.min_by { |p| p[:per_unit_price] }
      else
        prices = prices_by_supplier.select { |p| p[:price].present? && p[:price] > 0 && p[:in_stock] }
        prices.min_by { |p| p[:price] } if prices.any?
      end
    end
  end

  def most_expensive_supplier
    @most_expensive_supplier ||= begin
      if per_unit_comparable?
        comparable_group.max_by { |p| p[:per_unit_price] }
      else
        prices = prices_by_supplier.select { |p| p[:price].present? && p[:price] > 0 && p[:in_stock] }
        prices.max_by { |p| p[:price] } if prices.any?
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

  private

  # Uses detect on the preloaded collection instead of find_by (which always hits DB)
  def primary_item
    product_match_items.detect { |pmi| pmi.is_primary }&.supplier_list_item
  end
end
