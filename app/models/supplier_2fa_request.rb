class Supplier2faRequest < ApplicationRecord
  # Associations
  belongs_to :user
  belongs_to :supplier_credential

  # Validations
  validates :session_token, presence: true, uniqueness: true
  validates :request_type, presence: true, inclusion: { in: %w[login checkout price_refresh] }
  validates :status, inclusion: { 
    in: %w[pending submitted verified failed expired cancelled] 
  }
  validates :expires_at, presence: true

  # Scopes
  scope :pending, -> { where(status: "pending") }
  scope :active, -> { pending.where("expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }

  # Constants
  MAX_ATTEMPTS = 3
  TIMEOUT_MINUTES = 5

  # Callbacks
  before_validation :generate_session_token, on: :create
  before_validation :set_expiration, on: :create

  # Methods
  def pending?
    status == "pending"
  end

  def submitted?
    status == "submitted"
  end

  def verified?
    status == "verified"
  end

  def failed?
    status == "failed"
  end

  def expired?
    status == "expired" || expires_at <= Time.current
  end

  def cancelled?
    status == "cancelled"
  end

  def active?
    pending? && !expired?
  end

  def can_retry?
    attempts < MAX_ATTEMPTS && !expired?
  end

  def attempts_remaining
    MAX_ATTEMPTS - attempts
  end

  def time_remaining
    return 0 if expired?
    (expires_at - Time.current).to_i
  end

  def record_attempt!(code)
    increment!(:attempts)
    update!(code_submitted: code, status: "submitted")
  end

  def mark_verified!
    update!(status: "verified", verified_at: Time.current)
  end

  def mark_failed!
    update!(status: "failed")
  end

  def mark_expired!
    update!(status: "expired")
  end

  def mark_cancelled!
    update!(status: "cancelled")
  end

  def supplier
    supplier_credential.supplier
  end

  private

  def generate_session_token
    self.session_token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_expiration
    self.expires_at ||= TIMEOUT_MINUTES.minutes.from_now
  end
end
