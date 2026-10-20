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

  # Sync invoice from Stripe. Resolves user/org from the invoice's subscription
  # first, then the canonical Organization#stripe_customer_id mapping, then the
  # legacy User#stripe_customer_id column.
  #
  # Returns nil (saves nothing) when the invoice can't be tied to anyone, e.g.
  # a customer we have no record of. The caller reports that as not-found.
  def self.sync_from_stripe(stripe_invoice, user: nil, subscription: nil)
    invoice = find_or_initialize_by(stripe_invoice_id: stripe_invoice.id)

    if subscription.nil?
      stripe_sub_id = stripe_subscription_id_for(stripe_invoice)
      subscription = Subscription.find_by(stripe_subscription_id: stripe_sub_id) if stripe_sub_id
    end

    organization = subscription&.organization
    user ||= subscription&.user || organization&.owner

    if user.nil? && stripe_invoice.customer
      organization ||= Organization.find_by(stripe_customer_id: stripe_invoice.customer)
      user = organization&.owner || User.find_by(stripe_customer_id: stripe_invoice.customer)
    end
    organization ||= user&.current_organization

    return nil if user.nil? && invoice.user.nil?

    invoice.assign_attributes(
      user: user || invoice.user,
      organization_id: organization&.id || invoice.organization_id,
      subscription: subscription || invoice.subscription,
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

  # API 2025-03-31.basil moved the subscription reference from
  # invoice.subscription to invoice.parent.subscription_details.subscription;
  # the pinned 2026-02-25.clover payloads only carry the new one. Bracket
  # access because a StripeObject raises on a missing attribute.
  def self.stripe_subscription_id_for(stripe_invoice)
    parent = stripe_invoice['parent']
    ref = if parent && parent['type'] == 'subscription_details'
            parent['subscription_details'] && parent['subscription_details']['subscription']
          else
            stripe_invoice['subscription']
          end
    ref.respond_to?(:id) ? ref.id : ref.presence
  end
end
