class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :trackable, :lockable

  # Associations
  # Organization memberships
  has_many :memberships, dependent: :destroy
  has_many :organizations, through: :memberships
  belongs_to :current_organization, class_name: "Organization", optional: true

  # Personal resources (legacy - will be moved to organization)
  has_many :locations, dependent: :destroy
  has_many :supplier_credentials, dependent: :destroy
  has_many :suppliers, through: :supplier_credentials
  has_many :order_lists, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :supplier_2fa_requests, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :billing_events, dependent: :nullify

  # Invitations sent by this user
  has_many :sent_invitations, class_name: "OrganizationInvitation", foreign_key: :invited_by_id

  # Validations
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: %w[user super_admin] }

  # System-level roles (different from organization roles):
  # - user: Regular user, access determined by organization membership
  # - super_admin: Platform owner/support staff, can access any organization for support

  # Scopes
  scope :super_admins, -> { where(role: "super_admin") }
  scope :active, -> { where(locked_at: nil) }

  # System-level role checks (platform-wide, not organization-specific)
  def super_admin?
    role == "super_admin"
  end

  # Alias for backwards compatibility and clarity
  def platform_admin?
    super_admin?
  end

  def full_name
    [first_name, last_name].compact.join(" ").presence || email
  end

  def default_location
    locations.find_by(is_default: true) || locations.first
  end

  def active_credentials
    supplier_credentials.where(status: "active")
  end

  def credential_for(supplier)
    supplier_credentials.find_by(supplier: supplier)
  end

  # Organization methods
  def organization
    current_organization
  end

  def has_organization?
    current_organization.present?
  end

  def membership_for(org)
    memberships.find_by(organization: org)
  end

  def role_in(org)
    membership_for(org)&.role
  end

  def owner_of?(org)
    role_in(org) == "owner"
  end

  def admin_of?(org)
    super_admin? || %w[owner admin].include?(role_in(org))
  end

  def manager_of?(org)
    super_admin? || %w[owner admin manager].include?(role_in(org))
  end

  def member_of?(org)
    super_admin? || memberships.exists?(organization: org, active: true)
  end

  # Super admins can impersonate/access any organization for support
  def can_access_any_organization?
    super_admin?
  end

  # For support: access an organization without being a member
  def impersonate_organization!(org)
    raise "Not authorized" unless super_admin?

    update!(current_organization: org)
  end

  # Create a new organization with this user as owner
  def create_organization!(name:, **attributes)
    transaction do
      org = Organization.create!(name: name, **attributes)
      memberships.create!(organization: org, role: "owner")
      update!(current_organization: org) if current_organization.nil?
      org
    end
  end

  # Switch to a different organization
  def switch_organization!(org)
    raise "Not a member of this organization" unless member_of?(org)

    update!(current_organization: org)
  end

  # Subscription methods (now delegates to organization when present)
  def current_subscription
    # Check organization subscription first, fall back to personal
    current_organization&.current_subscription || subscriptions.active_or_trialing.order(created_at: :desc).first
  end

  def subscribed?
    # Check organization subscription first, fall back to personal
    current_organization&.subscribed? || current_subscription&.allows_access? || false
  end

  def subscription_status
    current_subscription&.status || "none"
  end

  def trialing?
    current_subscription&.trialing? || false
  end

  def subscription_past_due?
    subscriptions.past_due.exists?
  end

  def trial_days_remaining
    current_subscription&.trial_days_remaining || 0
  end

  # Get or create Stripe customer
  def find_or_create_stripe_customer
    return Stripe::Customer.retrieve(stripe_customer_id) if stripe_customer_id.present?

    customer = Stripe::Customer.create(
      email: email,
      name: full_name,
      metadata: {
        user_id: id
      }
    )

    update!(stripe_customer_id: customer.id)
    customer
  end

  # Create checkout session for subscription
  def create_checkout_session(success_url:, cancel_url:)
    customer = find_or_create_stripe_customer
    config = Rails.application.config.stripe_config

    Stripe::Checkout::Session.create(
      customer: customer.id,
      payment_method_types: ["card"],
      line_items: [{
        price: config[:monthly_price_id],
        quantity: 1
      }],
      mode: "subscription",
      subscription_data: {
        trial_period_days: config[:trial_days],
        metadata: {
          user_id: id
        }
      },
      success_url: success_url,
      cancel_url: cancel_url,
      allow_promotion_codes: true
    )
  end

  # Create billing portal session
  def create_billing_portal_session(return_url:)
    raise "No Stripe customer" unless stripe_customer_id

    Stripe::BillingPortal::Session.create(
      customer: stripe_customer_id,
      return_url: return_url
    )
  end
end
