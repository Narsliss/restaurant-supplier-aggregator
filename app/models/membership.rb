class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  ROLES = %w[owner admin manager member].freeze

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :organization_id, message: "is already a member of this organization" }

  # Scopes
  scope :active, -> { where(active: true) }
  scope :owners, -> { where(role: "owner") }
  scope :admins, -> { where(role: %w[owner admin]) }

  # Role checks
  def owner?
    role == "owner"
  end

  def admin?
    %w[owner admin].include?(role)
  end

  def manager?
    %w[owner admin manager].include?(role)
  end

  # Invitation methods
  def pending_invitation?
    invitation_token.present? && invitation_accepted_at.nil?
  end

  def accept_invitation!
    update!(
      invitation_accepted_at: Time.current,
      invitation_token: nil,
      active: true
    )
  end

  # Deactivation
  def deactivate!
    update!(active: false, deactivated_at: Time.current)
  end

  def reactivate!
    update!(active: true, deactivated_at: nil)
  end

  # Display
  def role_display
    role.titleize
  end
end
