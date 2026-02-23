class OrganizationInvitation < ApplicationRecord
  belongs_to :organization
  belongs_to :invited_by, class_name: "User"
  belongs_to :location, optional: true  # For chef invitations (single restaurant)

  ROLES = %w[manager chef].freeze # Can't invite as owner

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { scope: :organization_id, message: "has already been invited to this organization" }
  validates :role, presence: true, inclusion: { in: ROLES }
  validates :token, presence: true, uniqueness: true
  validate :chef_requires_location
  validate :manager_requires_location_ids
  validate :organization_has_seats, on: :create

  # Scopes
  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }
  scope :accepted, -> { where.not(accepted_at: nil) }

  # Callbacks
  before_validation :generate_token, on: :create
  before_validation :set_expiration, on: :create

  # Check if invitation is still valid
  def pending?
    accepted_at.nil? && expires_at > Time.current
  end

  def expired?
    expires_at <= Time.current
  end

  def accepted?
    accepted_at.present?
  end

  # Accept the invitation for a user
  def accept!(user)
    return false if expired? || accepted?

    transaction do
      # Create membership
      membership = organization.memberships.create!(
        user: user,
        role: role,
        invitation_accepted_at: Time.current
      )

      # Create location assignments
      if role == 'chef' && location_id.present?
        MembershipLocation.create!(membership: membership, location_id: location_id)
      elsif role == 'manager' && location_ids.present?
        location_ids.each do |lid|
          MembershipLocation.create!(membership: membership, location_id: lid)
        end
      end

      # Mark invitation as accepted
      update!(accepted_at: Time.current)

      # Set as user's current organization if they don't have one
      user.update!(current_organization: organization) if user.current_organization.nil?

      membership
    end
  end

  # Resend invitation
  def resend!
    return false unless pending?

    update!(
      expires_at: 7.days.from_now,
      invitation_sent_at: Time.current
    )

    # TODO: Send email
    true
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_expiration
    self.expires_at ||= 7.days.from_now
  end

  def chef_requires_location
    if role == 'chef' && location_id.blank?
      errors.add(:location_id, "is required for chef invitations (must assign a restaurant)")
    end
  end

  def manager_requires_location_ids
    if role == 'manager' && (location_ids.blank? || location_ids.empty?)
      errors.add(:location_ids, "are required for manager invitations (must assign at least one restaurant)")
    end
  end

  def organization_has_seats
    return unless organization
    unless organization.seats_available?
      errors.add(:base, "Organization has reached its seat limit (#{organization.seat_limit}). Contact support to add more seats.")
    end
  end
end
