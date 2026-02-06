class BillingEvent < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :subscription, optional: true

  validates :stripe_event_id, presence: true, uniqueness: true
  validates :event_type, presence: true

  scope :unprocessed, -> { where(processed: false) }
  scope :failed, -> { where.not(error_message: nil) }
  scope :recent, -> { order(created_at: :desc).limit(100) }

  # Check if this event has already been processed (idempotency)
  def self.already_processed?(stripe_event_id)
    exists?(stripe_event_id: stripe_event_id, processed: true)
  end

  # Record a new event from Stripe webhook
  def self.record!(stripe_event, user: nil, subscription: nil)
    create!(
      stripe_event_id: stripe_event.id,
      event_type: stripe_event.type,
      data: stripe_event.data.to_h,
      user: user,
      subscription: subscription
    )
  end

  # Mark as processed
  def mark_processed!
    update!(processed: true)
  end

  # Mark as failed with error
  def mark_failed!(error)
    update!(
      processed: false,
      error_message: error.message
    )
  end
end
