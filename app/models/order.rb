class Order < ApplicationRecord
  # Associations
  belongs_to :user
  belongs_to :location, optional: true
  belongs_to :supplier
  belongs_to :order_list, optional: true
  has_many :order_items, dependent: :destroy
  has_many :order_validations, dependent: :destroy
  has_many :supplier_products, through: :order_items

  # Validations
  validates :status, presence: true, inclusion: { 
    in: %w[pending processing pending_review pending_manual submitted confirmed failed cancelled] 
  }

  # Scopes
  scope :pending, -> { where(status: "pending") }
  scope :processing, -> { where(status: "processing") }
  scope :submitted, -> { where(status: "submitted") }
  scope :confirmed, -> { where(status: "confirmed") }
  scope :failed, -> { where(status: "failed") }
  scope :completed, -> { where(status: %w[submitted confirmed]) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_date, ->(date) { where(submitted_at: date.all_day) }

  # Status constants
  STATUSES = {
    pending: "pending",
    processing: "processing",
    pending_review: "pending_review",
    pending_manual: "pending_manual",
    submitted: "submitted",
    confirmed: "confirmed",
    failed: "failed",
    cancelled: "cancelled"
  }.freeze

  # Methods
  def pending?
    status == "pending"
  end

  def processing?
    status == "processing"
  end

  def submitted?
    status == "submitted"
  end

  def confirmed?
    status == "confirmed"
  end

  def failed?
    status == "failed"
  end

  def cancelled?
    status == "cancelled"
  end

  def completed?
    submitted? || confirmed?
  end

  def can_submit?
    pending? || status == "pending_review"
  end

  def can_cancel?
    pending? || processing? || status == "pending_review"
  end

  def calculated_subtotal
    order_items.sum(&:line_total)
  end

  def recalculate_totals!
    self.subtotal = calculated_subtotal
    self.total_amount = subtotal + (tax || 0)
    save!
  end

  def item_count
    order_items.sum(:quantity)
  end

  def build_from_order_list!(order_list, supplier)
    transaction do
      order_list.order_list_items.each do |list_item|
        supplier_product = list_item.product.supplier_product_for(supplier)
        next unless supplier_product&.current_price

        order_items.create!(
          supplier_product: supplier_product,
          quantity: list_item.quantity,
          unit_price: supplier_product.current_price,
          line_total: supplier_product.current_price * list_item.quantity
        )
      end

      recalculate_totals!
      order_list.mark_used!
    end
  end

  def submit!
    Orders::OrderPlacementService.new(self).place_order
  end

  def cancel!
    return false unless can_cancel?
    update!(status: "cancelled")
  end

  def validation_errors
    order_validations.where(passed: false).pluck(:message)
  end

  def validation_warnings
    order_validations.where(passed: true).where.not(message: nil).pluck(:message)
  end
end
