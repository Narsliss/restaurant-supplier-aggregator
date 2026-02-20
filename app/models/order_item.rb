class OrderItem < ApplicationRecord
  # Associations
  belongs_to :order
  belongs_to :supplier_product

  # Validations
  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :unit_price, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :line_total, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: %w[pending added failed skipped] }

  # Scopes
  scope :pending, -> { where(status: "pending") }
  scope :added, -> { where(status: "added") }
  scope :failed, -> { where(status: "failed") }
  scope :skipped, -> { where(status: "skipped") }

  # Callbacks
  before_validation :calculate_line_total

  # Delegations
  delegate :supplier_sku, :supplier_name, :supplier, to: :supplier_product
  delegate :product, to: :supplier_product

  # Methods
  def pending?
    status == "pending"
  end

  def added?
    status == "added"
  end

  def failed?
    status == "failed"
  end

  def skipped?
    status == "skipped"
  end

  def mark_added!
    update!(status: "added")
  end

  def mark_failed!(notes = nil)
    update!(status: "failed", notes: notes)
  end

  def mark_skipped!(reason = nil)
    update!(status: "skipped", notes: reason)
  end

  def price_changed?
    supplier_product.current_price != unit_price
  end

  def current_price_difference
    return 0 unless price_changed?
    supplier_product.current_price - unit_price
  end

  def update_to_current_price!
    new_price = supplier_product.current_price
    update!(
      unit_price: new_price,
      line_total: new_price * quantity
    )
    order.recalculate_totals!
  end

  # --- Price verification ---

  def verified_price_difference
    return 0 unless verified_price.present?
    verified_price - unit_price
  end

  def verified_price_changed?
    verified_price.present? && verified_price != unit_price
  end

  def verified_price_change_percentage
    return 0 unless verified_price_changed? && unit_price > 0
    ((verified_price - unit_price) / unit_price * 100).round(1)
  end

  private

  def calculate_line_total
    if quantity.present? && unit_price.present?
      self.line_total = quantity * unit_price
    end
  end
end
