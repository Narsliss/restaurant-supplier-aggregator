class SupplierCredential < ApplicationRecord
  # Encryption
  attr_encrypted :username, key: :encryption_key
  attr_encrypted :password, key: :encryption_key
  attr_encrypted :session_data, key: :encryption_key

  # Associations
  belongs_to :user
  belongs_to :supplier
  belongs_to :organization, optional: true
  has_many :supplier_2fa_requests, dependent: :destroy
  has_many :supplier_lists, dependent: :destroy

  # Validations
  validates :username, presence: true
  validates :password, presence: true, unless: :supplier_no_password?
  validates :supplier_id, uniqueness: {
    scope: :user_id,
    message: 'credential already exists for this supplier'
  }
  validates :status, inclusion: {
    in: %w[pending active expired failed hold]
  }

  # Password is optional for 2FA-only and welcome_url suppliers
  def supplier_uses_2fa_only?
    supplier&.two_fa_only?
  end

  def supplier_uses_welcome_url?
    supplier&.welcome_url_auth?
  end

  # No password needed for 2FA-only or welcome_url auth
  def supplier_no_password?
    supplier&.no_password_required?
  end

  # Scopes
  scope :active, -> { where(status: 'active') }
  scope :needs_refresh, -> { where('last_login_at < ?', 6.hours.ago) }
  scope :for_supplier, ->(supplier) { where(supplier: supplier) }

  # Status constants
  STATUSES = {
    pending: 'pending',
    active: 'active',
    expired: 'expired',
    failed: 'failed',
    hold: 'hold'
  }.freeze

  # Methods
  def active?
    status == 'active'
  end

  def expired?
    status == 'expired'
  end

  def failed?
    status == 'failed'
  end

  def on_hold?
    status == 'hold' || account_on_hold?
  end

  def needs_refresh?
    last_login_at.nil? || last_login_at < 6.hours.ago
  end

  def mark_active!
    update!(status: 'active', last_login_at: Time.current, last_error: nil)
  end

  def mark_failed!(error_message)
    update!(status: 'failed', last_error: error_message)
  end

  def mark_expired!
    update!(status: 'expired')
  end

  def mark_on_hold!(reason)
    update!(status: 'hold', account_on_hold: true, hold_reason: reason)
  end

  def clear_session!
    update!(session_data: nil)
  end

  def session_valid?
    return false unless session_data.present? && last_login_at.present?

    # Use different TTLs based on supplier auth type:
    # - 2FA suppliers (US Foods, PPO): sessions typically last 24+ hours on the
    #   supplier side. Use 24h so we don't show "Disconnected" prematurely.
    #   If the session IS dead, soft_refresh will catch it when verification runs.
    # - Password suppliers (CW, WCW): can auto-login anytime, so a shorter window
    #   just means we'll re-authenticate — no user impact.
    ttl = supplier&.no_password_required? ? 24.hours : 6.hours
    last_login_at > ttl.ago
  end

  def trusted_device_valid?
    trusted_device_token.present? &&
      trusted_device_expires_at.present? &&
      trusted_device_expires_at > Time.current
  end

  private

  def encryption_key
    Rails.application.credentials.encryption_key ||
      ENV['ENCRYPTION_KEY'] ||
      Rails.application.secret_key_base[0..31]
  end
end
