class Product < ApplicationRecord
  # Associations
  has_many :supplier_products, dependent: :destroy
  has_many :suppliers, through: :supplier_products
  has_many :order_list_items, dependent: :destroy
  has_many :order_lists, through: :order_list_items

  # Validations
  validates :name, presence: true

  # Scopes
  scope :search, lambda { |query|
    terms = query.to_s.strip.split(/\s+/).reject(&:blank?)
    return none if terms.empty?

    # Each word must appear in name, normalized_name, OR upc.
    # This lets "chicken breast" match "Breast Chicken Tender" etc.
    relation = all
    terms.each do |term|
      pattern = "%#{term}%"
      relation = relation.where(
        'name LIKE :q OR normalized_name LIKE :q OR upc LIKE :q', q: pattern
      )
    end
    relation
  }
  scope :by_category, ->(category) { where(category: category) }
  scope :with_prices, lambda {
    joins(:supplier_products).where(supplier_products: { discontinued: false }).where.not(supplier_products: { current_price: nil })
  }

  # Callbacks
  before_save :set_normalized_name

  # Methods
  def price_for(supplier)
    supplier_products.find_by(supplier: supplier)&.current_price
  end

  def available_at?(supplier)
    sp = supplier_products.find_by(supplier: supplier)
    sp&.in_stock?
  end

  def cheapest_supplier
    supplier_products
      .available
      .where(in_stock: true)
      .where.not(current_price: nil)
      .order(:current_price)
      .first
      &.supplier
  end

  def price_range
    prices = supplier_products.available.where.not(current_price: nil).pluck(:current_price)
    return nil if prices.empty?

    { min: prices.min, max: prices.max, spread: prices.max - prices.min }
  end

  def price_range
    prices = supplier_products.where.not(current_price: nil).pluck(:current_price)
    return nil if prices.empty?

    { min: prices.min, max: prices.max, spread: prices.max - prices.min }
  end

  def supplier_product_for(supplier)
    supplier_products.find_by(supplier: supplier)
  end

  private

  def set_normalized_name
    self.normalized_name = name&.downcase&.gsub(/[^a-z0-9\s]/, '')&.squish
  end
end
