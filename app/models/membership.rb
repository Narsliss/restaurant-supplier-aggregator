class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  # Location assignments (which restaurants this member can access)
  has_many :membership_locations, dependent: :destroy
  has_many :locations, through: :membership_locations

  ROLES = %w[owner manager chef].freeze

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :organization_id, message: "is already a member of this organization" }

  # Scopes
  scope :active, -> { where(active: true) }
  scope :owners, -> { where(role: "owner") }
  scope :managers, -> { where(role: "manager") }
  scope :chefs, -> { where(role: "chef") }

  # Role checks
  def owner?
    role == "owner"
  end

  def manager?
    role == "manager"
  end

  def chef?
    role == "chef"
  end

  # Returns locations this member can access:
  # - Owners: all org locations (implicit, not stored in join table)
  # - Managers/Chefs: only their assigned locations
  def assigned_locations
    if owner?
      organization.locations
    else
      locations
    end
  end

  def assigned_to_location?(location)
    return true if owner?
    membership_locations.exists?(location: location)
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
