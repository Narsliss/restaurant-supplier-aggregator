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
  validate :location_belongs_to_same_organization

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

  # A line "saving" more than this multiple of what was actually paid is a data
  # error (cross-unit price mismatch / bad scrape), not a real deal. Genuine
  # food-service spreads are well under 5x. See #calculate_savings.
  MAX_SAVINGS_MULTIPLE = 5

  # Drafts auto-expire after this many days of inactivity. Touching draft_saved_at
  # (e.g., when the chef reopens the draft on the review page) resets the timer.
  DRAFT_EXPIRY_DAYS = 14

  # Returns days remaining before this draft auto-expires. Nil for non-drafts.
  def draft_expires_in_days
    return nil unless draft? && draft_saved_at.present?
    remaining = (draft_saved_at + DRAFT_EXPIRY_DAYS.days - Time.current) / 1.day
    [remaining.ceil, 0].max
  end

  # True when the supplier flagged issues after submission (out of stock,
  # substitutions, short-fills, price change). See CheckOrderExceptionsJob.
  def has_supplier_exceptions?
    supplier_exceptions.present?
  end

  # Deep-link to fix an exception order on the supplier's own site. The chef
  # logs in there (we can't SSO through 2FA) and resolves it. US Foods only.
  def supplier_order_url
    return nil unless supplier&.code == "usfoods"

    "https://order.usfoods.com/desktop/order"
  end

  # True while we're still waiting on the post-submission exception check for a
  # freshly-submitted USF order — the order page keeps polling until it lands.
  def awaiting_exception_check?
    supplier&.code == "usfoods" &&
      status == "submitted" &&
      exceptions_checked_at.nil? &&
      submitted_at.present? && submitted_at > 10.minutes.ago
  end

  # Canonical image (from the product match) for a given order item, for display
  # on the review/placed-order screens. Each line is a specific supplier product;
  # we resolve back to the ProductMatch that owns it (scoped to this order's org)
  # and use its canonical image source. Returns a SupplierProduct or nil.
  def canonical_image_source_for(order_item)
    canonical_image_sources_by_supplier_product[order_item.supplier_product_id]
  end

  # Builds supplier_product_id => canonical image source (SupplierProduct) once
  # per order, so the views avoid N+1 lookups.
  #
  # This is decorative (a thumbnail) and runs on the checkout/review + order
  # pages. It must NEVER be able to break those pages, so any failure degrades
  # to "no image" rather than raising — image resolution can't block an order.
  def canonical_image_sources_by_supplier_product
    @canonical_image_sources_by_supplier_product ||= begin
      sp_ids = order_items.filter_map(&:supplier_product_id).uniq
      if sp_ids.empty? || organization_id.blank?
        {}
      else
        by_sp = {}
        ProductMatchItem
          .joins(:supplier_list_item, product_match: :aggregated_list)
          .where(supplier_list_items: { supplier_product_id: sp_ids })
          .where(aggregated_lists: { organization_id: organization_id })
          .includes(product_match: [:canonical_image_supplier_product,
                                    { product_match_items: { supplier_list_item: :supplier_product } }])
          .each do |pmi|
            spid = pmi.supplier_list_item.supplier_product_id
            by_sp[spid] ||= pmi.product_match.canonical_image_source
          end
        by_sp
      end
    rescue StandardError => e
      Rails.logger.warn("[Order#canonical_image_sources] order=#{id} failed: #{e.class}: #{e.message}")
      {}
    end
  end

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

  def received?
    received_at.present?
  end

  def mark_received!
    update!(received_at: Time.current)
  end

  def mark_unreceived!
    update!(received_at: nil)
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

        # estimated_case_price: catch-weight products store current_price per LB
        case_price = supplier_product.estimated_case_price
        order_items.create!(
          supplier_product: supplier_product,
          quantity: list_item.quantity,
          unit_price: case_price,
          line_total: case_price * list_item.quantity
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

  # Savings vs. the most expensive supplier carrying the same product,
  # computed PER LINE so one bad comparison can't swamp the order.
  #
  # Two guards, both added after order #80 recorded $4,738.37 "saved" on
  # $233.80 spent (2,027%):
  #   1. Peer prices are compared as case-equivalents — a catch-weight
  #      per-LB price is not a case price (SupplierProduct#estimated_case_price).
  #   2. A line whose apparent savings exceeds MAX_SAVINGS_MULTIPLE× what was
  #      actually paid is treated as a data error (cross-unit mismatch or bad
  #      scrape) and skipped, not trusted.
  def calculate_savings
    savings_breakdown[:realized]
  end

  # Persist both halves together. They come from one calculation and drift
  # apart if written separately.
  def recalculate_savings!
    breakdown = savings_breakdown
    update!(savings_amount: breakdown[:realized], missed_savings_amount: breakdown[:missed])
    breakdown
  end

  # The other half of the same calculation: what was left on the table.
  def calculate_missed_savings
    savings_breakdown[:missed]
  end

  # Both sides at once, from the one definition in Orders::SavingsCalculator.
  #
  # realized = (dearest comparable peer - what you paid) x what you bought
  # missed   = (what you paid - cheapest peer)          x what you bought
  #
  # They always sum to the market spread on the line, so a middle pick earns
  # both and no choice falls into a gap. Peers come from the Product spine, the
  # chef's own matched lists, and the automatic basket candidates.
  def savings_breakdown
    items = order_items.includes(:supplier_product).to_a
    return { realized: 0, missed: 0, compared: 0, lines: 0 } if items.empty?

    peers = ComparisonCandidate.peers_for(items.filter_map(&:supplier_product))
    realized = 0.0
    missed = 0.0
    compared = 0

    items.each do |item|
      result = Orders::SavingsCalculator.call(item, peers[item.supplier_product_id] || [])
      next unless result.comparable?

      compared += 1
      realized += result.realized
      missed += result.missed
    end

    { realized: realized.round(2), missed: missed.round(2), compared: compared, lines: items.size }
  end

  # Per-line savings, or 0 when there's no valid/plausible comparison.
  def line_savings_for(item, peers_by_product)
    product_id = item.supplier_product&.product_id
    return 0 unless product_id

    paid = item.line_total.to_f
    return 0 unless paid.positive?

    worst_unit = peers_by_product[product_id].to_a.map { |p| p.estimated_case_price.to_f }.max
    return 0 unless worst_unit&.positive?

    savings = (worst_unit * item.quantity.to_f) - paid
    return 0 unless savings.positive?

    if savings > paid * MAX_SAVINGS_MULTIPLE
      Rails.logger.warn "[Savings] Order ##{id} item ##{item.id}: implausible savings " \
                        "$#{savings.round(2)} on $#{paid.round(2)} paid (worst unit $#{worst_unit.round(2)}) — skipping"
      return 0
    end

    savings
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

  def location_belongs_to_same_organization
    return unless location_id_changed? && location.present? && organization_id.present?
    if location.organization_id != organization_id
      errors.add(:location_id, "must be in this organization")
    end
  end
end
