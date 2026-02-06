class Subscription < ApplicationRecord
  belongs_to :user
  has_many :billing_events, dependent: :nullify
  has_many :invoices, dependent: :nullify

  # Status constants matching Stripe subscription statuses
  STATUSES = %w[
    incomplete
    incomplete_expired
    trialing
    active
    past_due
    canceled
    unpaid
    paused
  ].freeze

  validates :stripe_subscription_id, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active_or_trialing, -> { where(status: %w[active trialing]) }
  scope :past_due, -> { where(status: "past_due") }
  scope :canceled, -> { where(status: "canceled") }
  scope :expiring_soon, -> { where("current_period_end < ?", 7.days.from_now) }

  # Check if subscription allows access to the app
  def allows_access?
    %w[active trialing past_due].include?(status)
  end

  # Check if in trial period
  def trialing?
    status == "trialing"
  end

  # Check if subscription is active (not trialing)
  def active?
    status == "active"
  end

  # Check if past due (grace period)
  def past_due?
    status == "past_due"
  end

  # Check if canceled but still has time remaining
  def canceled_but_active?
    cancel_at_period_end? && current_period_end&.future?
  end

  # Days remaining in current period
  def days_remaining
    return 0 unless current_period_end

    [(current_period_end.to_date - Date.current).to_i, 0].max
  end

  # Days remaining in trial
  def trial_days_remaining
    return 0 unless trialing? && trial_end

    [(trial_end.to_date - Date.current).to_i, 0].max
  end

  # Format amount for display
  def formatted_amount
    "$#{'%.2f' % (amount_cents / 100.0)}/#{interval}"
  end

  # Sync subscription from Stripe
  def self.sync_from_stripe(stripe_subscription, user: nil)
    subscription = find_or_initialize_by(stripe_subscription_id: stripe_subscription.id)

    subscription.assign_attributes(
      user: user || subscription.user,
      stripe_price_id: stripe_subscription.items.data.first&.price&.id,
      status: stripe_subscription.status,
      current_period_start: Time.zone.at(stripe_subscription.current_period_start),
      current_period_end: Time.zone.at(stripe_subscription.current_period_end),
      cancel_at_period_end: stripe_subscription.cancel_at_period_end,
      canceled_at: stripe_subscription.canceled_at ? Time.zone.at(stripe_subscription.canceled_at) : nil,
      ended_at: stripe_subscription.ended_at ? Time.zone.at(stripe_subscription.ended_at) : nil,
      trial_start: stripe_subscription.trial_start ? Time.zone.at(stripe_subscription.trial_start) : nil,
      trial_end: stripe_subscription.trial_end ? Time.zone.at(stripe_subscription.trial_end) : nil,
      metadata: stripe_subscription.metadata.to_h
    )

    subscription.save!
    subscription
  end
end
