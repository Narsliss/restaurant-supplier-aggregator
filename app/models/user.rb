class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :trackable, :lockable

  # Associations
  has_many :locations, dependent: :destroy
  has_many :supplier_credentials, dependent: :destroy
  has_many :suppliers, through: :supplier_credentials
  has_many :order_lists, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :supplier_2fa_requests, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :billing_events, dependent: :nullify

  # Validations
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: %w[user manager admin] }

  # Scopes
  scope :admins, -> { where(role: "admin") }
  scope :managers, -> { where(role: "manager") }
  scope :active, -> { where(locked_at: nil) }

  # Methods
  def admin?
    role == "admin"
  end

  def manager?
    role == "manager"
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

  # Subscription methods
  def current_subscription
    subscriptions.active_or_trialing.order(created_at: :desc).first
  end

  def subscribed?
    current_subscription&.allows_access? || false
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
