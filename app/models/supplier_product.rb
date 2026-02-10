class SupplierProduct < ApplicationRecord
  # Associations
  belongs_to :product, optional: true
  belongs_to :supplier
  has_many :order_items, dependent: :restrict_with_error

  # Validations
  validates :supplier_sku, presence: true
  validates :supplier_sku, uniqueness: { scope: :supplier_id }
  validates :supplier_name, presence: true
  validates :current_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :minimum_quantity, numericality: { greater_than: 0 }, allow_nil: true
  validates :maximum_quantity, numericality: { greater_than: 0 }, allow_nil: true

  # Scopes
  scope :in_stock, -> { where(in_stock: true) }
  scope :out_of_stock, -> { where(in_stock: false) }
  scope :with_price, -> { where.not(current_price: nil) }
  scope :stale, -> { where("last_scraped_at < ? OR last_scraped_at IS NULL", 24.hours.ago) }
  scope :price_changed, -> { where.not(previous_price: nil).where("current_price != previous_price") }

  # Methods
  def in_stock?
    in_stock
  end

  def out_of_stock?
    !in_stock
  end

  def price_changed?
    previous_price.present? && current_price != previous_price
  end

  def price_change_percent
    return nil unless price_changed? && previous_price.to_f > 0
    ((current_price - previous_price) / previous_price * 100).round(2)
  end

  def price_increased?
    price_changed? && current_price > previous_price
  end

  def price_decreased?
    price_changed? && current_price < previous_price
  end

  def update_price!(new_price, in_stock: true)
    update!(
      previous_price: current_price,
      current_price: new_price,
      in_stock: in_stock,
      price_updated_at: Time.current,
      last_scraped_at: Time.current
    )
  end

  def stale?
    last_scraped_at.nil? || last_scraped_at < 24.hours.ago
  end

  # Pack size parsing and per-unit pricing

  def parsed_pack_size
    @parsed_pack_size ||= UnitParser.parse(pack_size)
  end

  def per_unit_price
    return nil unless current_price && parsed_pack_size[:parseable]
    return nil if parsed_pack_size[:normalized_quantity] <= 0

    (current_price / parsed_pack_size[:normalized_quantity]).round(4)
  end

  def normalized_unit
    parsed_pack_size[:parseable] ? parsed_pack_size[:normalized_unit] : nil
  end

  def comparable_with?(other)
    return false unless parsed_pack_size[:parseable] && other.parsed_pack_size[:parseable]

    normalized_unit == other.normalized_unit
  end

  def formatted_per_unit_price
    UnitParser.format_per_unit(per_unit_price, normalized_unit)
  end

  def line_total(quantity)
    return nil unless current_price
    current_price * quantity
  end

  def meets_minimum?(quantity)
    minimum_quantity.nil? || quantity >= minimum_quantity
  end

  def within_maximum?(quantity)
    maximum_quantity.nil? || quantity <= maximum_quantity
  end

  def quantity_valid?(quantity)
    meets_minimum?(quantity) && within_maximum?(quantity)
  end
end
