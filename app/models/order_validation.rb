class OrderValidation < ApplicationRecord
  # Associations
  belongs_to :order

  # Validations
  validates :validation_type, presence: true
  validates :passed, inclusion: { in: [true, false] }
  validates :validated_at, presence: true

  # Scopes
  scope :passed, -> { where(passed: true) }
  scope :failed, -> { where(passed: false) }
  scope :by_type, ->(type) { where(validation_type: type) }
  scope :recent, -> { order(validated_at: :desc) }

  # Validation types
  TYPES = %w[
    order_minimum
    item_minimum
    item_maximum
    item_unavailable
    items_removed
    cutoff_passed
    cutoff_approaching
    delivery_unavailable
    account_inactive
    account_hold
    service_area
    price_changed
  ].freeze

  # Methods
  def passed?
    passed
  end

  def failed?
    !passed
  end

  def blocking?
    failed? && %w[
      order_minimum
      item_minimum
      item_maximum
      item_unavailable
      cutoff_passed
      account_inactive
      account_hold
      service_area
    ].include?(validation_type)
  end

  def warning?
    passed? && message.present?
  end

  def detail(key)
    details&.dig(key.to_s)
  end
end
