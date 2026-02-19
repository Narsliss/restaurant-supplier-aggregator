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
      {
        supplier: pmi.supplier,
        item: pmi.supplier_list_item,
        price: pmi.supplier_list_item.price,
        pack_size: pmi.supplier_list_item.pack_size,
        in_stock: pmi.supplier_list_item.in_stock
      }
    end
  end

  def cheapest_supplier
    prices = prices_by_supplier.select { |p| p[:price].present? && p[:in_stock] }
    prices.min_by { |p| p[:price] }
  end

  def most_expensive_supplier
    prices = prices_by_supplier.select { |p| p[:price].present? && p[:in_stock] }
    prices.max_by { |p| p[:price] }
  end

  def price_spread
    prices = prices_by_supplier.select { |p| p[:price].present? }.map { |p| p[:price] }
    return nil if prices.size < 2

    prices.max - prices.min
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
