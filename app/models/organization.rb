class Organization < ApplicationRecord
  # Associations
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :subscriptions, dependent: :destroy
  has_many :locations, dependent: :destroy
  has_many :supplier_credentials, dependent: :destroy
  has_many :order_lists, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :organization_invitations, dependent: :destroy
  has_many :supplier_lists, dependent: :destroy
  has_many :aggregated_lists, dependent: :destroy

  # Validations
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9-]+\z/, message: 'can only contain lowercase letters, numbers, and hyphens' }

  # Callbacks
  before_validation :generate_slug, on: :create

  # Scopes
  scope :active, -> { where(active: true) }

  # Subscription methods
  def current_subscription
    subscriptions.active_or_trialing.order(created_at: :desc).first
  end

  def subscribed?
    current_subscription&.allows_access? || false
  end

  def subscription_status
    current_subscription&.status || 'none'
  end

  # Member methods
  def owner
    memberships.find_by(role: 'owner')&.user
  end

  def owners
    users.joins(:memberships).where(memberships: { role: 'owner', organization_id: id })
  end

  def admins
    users.joins(:memberships).where(memberships: { role: %w[owner admin], organization_id: id })
  end

  def active_members
    memberships.where(active: true).includes(:user)
  end

  def member_count
    memberships.where(active: true).count
  end

  # Check if user is a member
  def member?(user)
    memberships.exists?(user: user, active: true)
  end

  # Check user's role
  def role_for(user)
    memberships.find_by(user: user)&.role
  end

  def owner?(user)
    role_for(user) == 'owner'
  end

  def admin?(user)
    %w[owner admin].include?(role_for(user))
  end

  def manager?(user)
    %w[owner admin manager].include?(role_for(user))
  end

  # Stripe methods
  def find_or_create_stripe_customer
    return Stripe::Customer.retrieve(stripe_customer_id) if stripe_customer_id.present?

    customer = Stripe::Customer.create(
      name: name,
      email: owner&.email,
      metadata: {
        organization_id: id,
        organization_slug: slug
      }
    )

    update!(stripe_customer_id: customer.id)
    customer
  end

  def create_checkout_session(user:, success_url:, cancel_url:)
    customer = find_or_create_stripe_customer
    config = Rails.application.config.stripe_config

    Stripe::Checkout::Session.create(
      customer: customer.id,
      payment_method_types: ['card'],
      line_items: [{
        price: config[:monthly_price_id],
        quantity: 1
      }],
      mode: 'subscription',
      subscription_data: {
        trial_period_days: config[:trial_days],
        metadata: {
          organization_id: id,
          user_id: user.id
        }
      },
      success_url: success_url,
      cancel_url: cancel_url,
      allow_promotion_codes: true
    )
  end

  def create_billing_portal_session(return_url:)
    raise 'No Stripe customer' unless stripe_customer_id

    Stripe::BillingPortal::Session.create(
      customer: stripe_customer_id,
      return_url: return_url
    )
  end

  private

  def generate_slug
    return if slug.present?

    base_slug = name.to_s.parameterize
    self.slug = base_slug

    # Ensure uniqueness
    counter = 1
    while Organization.exists?(slug: slug)
      self.slug = "#{base_slug}-#{counter}"
      counter += 1
    end
  end
end
