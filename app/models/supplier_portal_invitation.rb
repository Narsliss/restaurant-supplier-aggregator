class SupplierPortalInvitation < ApplicationRecord
  belongs_to :supplier
  belongs_to :invited_by, polymorphic: true, optional: true

  ROLES = %w[admin rep].freeze

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { scope: :supplier_id, message: "has already been invited for this supplier" }
  validates :role, presence: true, inclusion: { in: ROLES }
  validates :token, presence: true, uniqueness: true

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }
  scope :accepted, -> { where.not(accepted_at: nil) }

  before_validation :generate_token, on: :create
  before_validation :set_expiration, on: :create

  def pending?
    accepted_at.nil? && expires_at > Time.current
  end

  def expired?
    expires_at <= Time.current
  end

  def accepted?
    accepted_at.present?
  end

  def accept!(supplier_user)
    return false if expired? || accepted?

    transaction do
      update!(accepted_at: Time.current)
      supplier_user.update!(invitation_accepted_at: Time.current)
    end

    true
  end

  def resend!
    return false unless pending?

    update!(expires_at: 7.days.from_now)
    true
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_expiration
    self.expires_at ||= 7.days.from_now
  end
end
