class OrderItem < ApplicationRecord
  # Associations
  belongs_to :order
  belongs_to :supplier_product, optional: true

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
  before_validation :snapshot_product_info, on: :create

  # Safe accessors that fall back to snapshot columns when supplier_product is deleted
  def supplier_name
    supplier_product&.supplier_name || product_name
  end

  def supplier_sku
    supplier_product&.supplier_sku || product_sku
  end

  def supplier
    supplier_product&.supplier
  end

  def product
    supplier_product&.product
  end

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

  # The current supplier price that corresponds to THIS line's chosen unit.
  # A piece (PC) line must be compared against the piece price, not the case
  # price — otherwise an $85.48 piece looks like a +445% jump from the $466.32
  # case and trips a false "price changed" alarm. Falls back to the case price
  # when no distinct piece price is stored (or the line isn't piece-ordered).
  def current_supplier_unit_price
    if uom == "PC" && supplier_product.piece_price.present? && supplier_product.piece_price.positive?
      supplier_product.piece_price
    else
      supplier_product.current_price
    end
  end

  def price_changed?
    current_supplier_unit_price != unit_price
  end

  def current_price_difference
    return 0 unless price_changed?
    current_supplier_unit_price - unit_price
  end

  def update_to_current_price!
    new_price = current_supplier_unit_price
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

  def snapshot_product_info
    self.product_name ||= supplier_product&.supplier_name
    self.product_sku ||= supplier_product&.supplier_sku
  end
end
