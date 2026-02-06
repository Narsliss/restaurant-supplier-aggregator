class Invoice < ApplicationRecord
  belongs_to :user
  belongs_to :subscription, optional: true

  validates :stripe_invoice_id, presence: true, uniqueness: true
  validates :status, presence: true

  scope :paid, -> { where(status: "paid") }
  scope :open, -> { where(status: "open") }
  scope :recent, -> { order(created_at: :desc) }

  # Format amount for display
  def formatted_amount_due
    "$#{'%.2f' % ((amount_due_cents || 0) / 100.0)}"
  end

  def formatted_amount_paid
    "$#{'%.2f' % ((amount_paid_cents || 0) / 100.0)}"
  end

  def paid?
    status == "paid"
  end

  # Sync invoice from Stripe
  def self.sync_from_stripe(stripe_invoice, user: nil, subscription: nil)
    invoice = find_or_initialize_by(stripe_invoice_id: stripe_invoice.id)

    # Find user from customer if not provided
    if user.nil? && stripe_invoice.customer
      user = User.find_by(stripe_customer_id: stripe_invoice.customer)
    end

    # Find subscription if not provided
    if subscription.nil? && stripe_invoice.subscription
      subscription = Subscription.find_by(stripe_subscription_id: stripe_invoice.subscription)
    end

    invoice.assign_attributes(
      user: user,
      subscription: subscription,
      status: stripe_invoice.status,
      amount_due_cents: stripe_invoice.amount_due,
      amount_paid_cents: stripe_invoice.amount_paid,
      currency: stripe_invoice.currency,
      hosted_invoice_url: stripe_invoice.hosted_invoice_url,
      invoice_pdf_url: stripe_invoice.invoice_pdf,
      period_start: stripe_invoice.period_start ? Time.zone.at(stripe_invoice.period_start) : nil,
      period_end: stripe_invoice.period_end ? Time.zone.at(stripe_invoice.period_end) : nil,
      paid_at: stripe_invoice.status_transitions&.paid_at ? Time.zone.at(stripe_invoice.status_transitions.paid_at) : nil
    )

    invoice.save!
    invoice
  end
end
