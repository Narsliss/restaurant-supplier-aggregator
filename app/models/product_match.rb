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

  # Price comparison across matched items
  def prices_by_supplier
    product_match_items.includes(:supplier_list_item, :supplier).map do |pmi|
      item = pmi.supplier_list_item
      {
        supplier: pmi.supplier,
        item: item,
        price: item.price,
        pack_size: item.pack_size,
        per_unit_price: item.per_unit_price,
        normalized_unit: item.normalized_unit,
        formatted_per_unit: item.formatted_per_unit_price,
        in_stock: item.in_stock
      }
    end
  end

  # Are per-unit prices comparable across suppliers? (same normalized unit)
  def per_unit_comparable?
    items = prices_by_supplier.select { |p| p[:price].present? && p[:in_stock] }
    units = items.filter_map { |p| p[:normalized_unit] }.uniq
    units.size == 1
  end

  def cheapest_supplier
    prices = prices_by_supplier.select { |p| p[:price].present? && p[:in_stock] }
    return nil if prices.empty?

    # Use per-unit price when all items share the same normalized unit
    if per_unit_comparable? && prices.all? { |p| p[:per_unit_price].present? }
      prices.min_by { |p| p[:per_unit_price] }
    else
      prices.min_by { |p| p[:price] }
    end
  end

  def most_expensive_supplier
    prices = prices_by_supplier.select { |p| p[:price].present? && p[:in_stock] }
    return nil if prices.empty?

    if per_unit_comparable? && prices.all? { |p| p[:per_unit_price].present? }
      prices.max_by { |p| p[:per_unit_price] }
    else
      prices.max_by { |p| p[:price] }
    end
  end

  def price_spread
    prices = prices_by_supplier.select { |p| p[:price].present? }
    return nil if prices.size < 2

    if per_unit_comparable? && prices.all? { |p| p[:per_unit_price].present? }
      prices.map { |p| p[:per_unit_price] }.max - prices.map { |p| p[:per_unit_price] }.min
    else
      prices.map { |p| p[:price] }.max - prices.map { |p| p[:price] }.min
    end
  end

  # Get the item for a specific supplier
  def item_for_supplier(supplier)
    product_match_items.find_by(supplier: supplier)&.supplier_list_item
  end

  # Display name
  def display_name
    canonical_name.presence || primary_item&.name || 'Unnamed Product'
  end

  private

  def primary_item
    product_match_items.find_by(is_primary: true)&.supplier_list_item
  end
end
