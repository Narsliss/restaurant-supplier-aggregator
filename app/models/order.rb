class Order < ApplicationRecord
  # Associations
  belongs_to :user
  belongs_to :location, optional: true
  belongs_to :supplier, optional: true
  belongs_to :order_list, optional: true
  has_many :order_items, dependent: :destroy
  has_many :order_validations, dependent: :destroy
  has_many :supplier_products, through: :order_items

  # Validations
  validates :status, presence: true, inclusion: {
    in: %w[pending verifying price_changed processing pending_review pending_manual submitted confirmed failed cancelled dry_run_complete draft]
  }
  validates :verification_status, inclusion: {
    in: %w[pending verifying verified price_changed failed skipped],
    allow_nil: true
  }

  # Organization scoping
  belongs_to :organization, optional: true

  before_validation :set_organization_from_user, on: :create
  before_validation :snapshot_supplier_name, on: :create

  # Scopes
  scope :for_location, ->(loc) { where(location: loc) }
  scope :for_locations, ->(locs) { where(location_id: locs.select(:id)) }
  scope :for_organization, ->(org) { where(organization_id: org.id) }
  scope :pending, -> { where(status: "pending") }
  scope :verifying, -> { where(status: "verifying") }
  scope :price_changed, -> { where(status: "price_changed") }
  scope :processing, -> { where(status: "processing") }
  scope :submitted, -> { where(status: "submitted") }
  scope :confirmed, -> { where(status: "confirmed") }
  scope :failed, -> { where(status: "failed") }
  scope :draft, -> { where(status: "draft") }
  scope :completed, -> { where(status: %w[submitted confirmed]) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_date, ->(date) { where(submitted_at: date.all_day) }
  scope :for_batch, ->(batch_id) { where(batch_id: batch_id) }
  scope :needs_verification, -> { where(verification_status: %w[pending verifying]) }
  scope :verification_complete, -> { where(verification_status: %w[verified price_changed failed skipped]) }

  # Status constants
  STATUSES = {
    pending: "pending",
    verifying: "verifying",
    price_changed: "price_changed",
    processing: "processing",
    pending_review: "pending_review",
    pending_manual: "pending_manual",
    submitted: "submitted",
    confirmed: "confirmed",
    failed: "failed",
    cancelled: "cancelled",
    dry_run_complete: "dry_run_complete",
    draft: "draft"
  }.freeze

  VERIFICATION_STATUSES = %w[pending verifying verified price_changed failed skipped].freeze

  # Statuses that represent real orders (submitted to suppliers) — used for KPI aggregation
  KPI_STATUSES = %w[submitted confirmed dry_run_complete].freeze

  scope :kpi_eligible, -> { where(status: KPI_STATUSES) }

  # Price change threshold — differences within 5% are auto-accepted
  PRICE_CHANGE_THRESHOLD = 0.05

  # Methods
  def pending?
    status == "pending"
  end

  def verifying?
    status == "verifying"
  end

  def price_changed?
    status == "price_changed"
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

  def dry_run_complete?
    status == "dry_run_complete"
  end

  def draft?
    status == "draft"
  end

  def completed?
    submitted? || confirmed? || dry_run_complete?
  end

  def editable?
    status.in?(%w[pending verifying price_changed pending_review draft])
  end

  def can_submit?
    pending? || status == "pending_review" || price_changed? || draft?
  end

  def can_cancel?
    pending? || processing? || verifying? || price_changed? || status == "pending_review" || draft?
  end

  def can_delete?
    status.in?(%w[pending verifying price_changed failed cancelled dry_run_complete draft])
  end

  # --- Price verification ---

  def start_verification!
    update!(
      status: "verifying",
      verification_status: "verifying"
    )
  end

  def mark_verified!(verified_total:)
    update!(
      verification_status: "verified",
      price_verified_at: Time.current,
      verified_total: verified_total,
      price_change_amount: 0,
      verification_error: nil
    )
  end

  def mark_price_changed!(verified_total:, price_change_amount:)
    update!(
      status: "price_changed",
      verification_status: "price_changed",
      price_verified_at: Time.current,
      verified_total: verified_total,
      price_change_amount: price_change_amount,
      verification_error: nil
    )
  end

  def mark_verification_failed!(error_message)
    update!(
      verification_status: "failed",
      verification_error: error_message,
      price_verified_at: Time.current
    )
  end

  def mark_as_draft!
    update!(
      status: "draft",
      draft_saved_at: Time.current
    )
  end

  def skip_verification!(reason = nil)
    update!(
      verification_status: "skipped",
      verification_error: reason
    )
  end

  def accept_price_changes!
    return unless price_changed?

    # Update each item to the verified price
    order_items.each do |item|
      next unless item.verified_price.present?
      item.update!(
        unit_price: item.verified_price,
        line_total: item.verified_price * item.quantity
      )
    end

    recalculate_totals!
    update!(
      status: "draft",
      verification_status: "verified",
      price_change_amount: 0,
      draft_saved_at: Time.current
    )
  end

  def verification_pending?
    verification_status == "pending"
  end

  def verification_in_progress?
    verification_status == "verifying"
  end

  def verification_complete?
    verification_status.in?(%w[verified price_changed failed skipped])
  end

  def prices_verified?
    verification_status == "verified"
  end

  def has_price_changes?
    verification_status == "price_changed"
  end

  def verification_failed?
    verification_status == "failed"
  end

  def price_change_percentage
    return 0 unless price_change_amount.present? && subtotal.present? && subtotal > 0
    (price_change_amount / subtotal * 100).round(1)
  end

  def within_price_threshold?
    return true unless price_change_amount.present? && subtotal.present? && subtotal > 0
    (price_change_amount.abs / subtotal) <= PRICE_CHANGE_THRESHOLD
  end

  def calculated_subtotal
    order_items.reload.sum(:line_total)
  end

  def recalculate_totals!
    self.subtotal = calculated_subtotal
    self.total_amount = subtotal + (tax || 0)
    save!
  end

  def display_supplier_name
    supplier&.name || supplier_name || "Deleted supplier"
  end

  def item_count
    order_items.sum(:quantity).to_i
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

  def calculate_savings
    return 0 if order_items.empty?

    product_ids = order_items.filter_map { |item| item.supplier_product&.product_id }
    worst_prices = SupplierProduct
      .where(product_id: product_ids, discontinued: false)
      .where.not(current_price: nil)
      .group(:product_id)
      .maximum(:current_price)

    worst_total = order_items.sum do |item|
      product_id = item.supplier_product&.product_id
      worst_price = product_id ? worst_prices[product_id] : nil
      ((worst_price || item.unit_price) * item.quantity)
    end

    [worst_total - (total_amount || calculated_subtotal), 0].max.round(2)
  end

  def validation_errors
    order_validations.where(passed: false).pluck(:message)
  end

  def validation_warnings
    order_validations.where(passed: true).where.not(message: nil).pluck(:message)
  end

  private

  def set_organization_from_user
    self.organization_id ||= user&.current_organization_id
  end

  def snapshot_supplier_name
    self.supplier_name ||= supplier&.name
  end
end
