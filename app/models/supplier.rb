class Supplier < ApplicationRecord
  # Associations
  has_many :supplier_credentials, dependent: :destroy
  has_many :users, through: :supplier_credentials
  has_many :supplier_products, dependent: :destroy
  has_many :products, through: :supplier_products
  has_many :supplier_requirements, dependent: :destroy
  has_many :supplier_delivery_schedules, dependent: :destroy
  has_many :orders, dependent: :nullify
  has_many :supplier_lists, dependent: :destroy
  has_many :product_match_items, dependent: :destroy
  has_many :supplier_users, dependent: :destroy
  has_many :supplier_portal_invitations, dependent: :destroy
  belongs_to :organization, optional: true
  belongs_to :creator, class_name: 'User', foreign_key: :created_by_id, optional: true

  # Validations
  validates :name, presence: true
  validates :code, presence: true, uniqueness: true
  validates :base_url, presence: true, unless: :email_supplier?
  validates :login_url, presence: true, unless: :email_supplier?
  validates :scraper_class, presence: true, unless: :email_supplier?
  validates :contact_email, presence: true, if: :email_supplier?

  # Scopes
  scope :active, -> { where(active: true) }
  scope :by_name, -> { order(:name) }
  scope :password_required, -> { where(password_required: true) }
  scope :two_fa_only, -> { where(password_required: false) }
  scope :email_suppliers, -> { where(auth_type: 'email') }
  scope :web_suppliers, -> { where.not(auth_type: 'email') }
  scope :for_organization, ->(org) { where(organization_id: [nil, org.id]) }

  # Authentication type constants
  AUTH_TYPES = %w[password two_fa welcome_url email].freeze

  validates :auth_type, inclusion: { in: AUTH_TYPES }

  # Authentication type helpers
  def two_fa_only?
    auth_type == 'two_fa'
  end

  def welcome_url_auth?
    auth_type == 'welcome_url'
  end

  def password_auth?
    auth_type == 'password'
  end

  def email_supplier?
    auth_type == 'email'
  end

  # Returns true if this supplier does NOT need a password
  # (2FA-only, welcome URL, or email auth)
  def no_password_required?
    !password_auth?
  end

  # Email supplier helpers
  def latest_price_list
    return nil unless email_supplier? && contact_email.present?
    InboundPriceList.latest_for(contact_email)
  end

  def price_list_stale?
    return false unless email_supplier?
    latest = latest_price_list
    return true unless latest&.parsed?
    latest.received_at < 3.weeks.ago
  end

  # Methods
  def scraper_klass
    scraper_class.constantize
  end

  def order_minimum(location = nil)
    SupplierRequirement.effective_for(supplier: self, type: 'order_minimum', location: location)&.numeric_value
  end

  def case_minimum(location = nil)
    SupplierRequirement.effective_for(supplier: self, type: 'case_minimum', location: location)&.numeric_value&.to_i
  end

  def cutoff_requirement
    supplier_requirements.find_by(requirement_type: 'cutoff_time', active: true)
  end

  def delivery_schedule_for(location)
    supplier_delivery_schedules.where(location: [location, nil], active: true)
  end

  def product_by_sku(sku)
    supplier_products.find_by(supplier_sku: sku)
  end

  def checkout_enabled?
    checkout_enabled
  end

  # Display helpers for compact card grid
  BRAND_COLORS = {
    'usfoods'            => 'text-red-500',
    'sysco'              => 'text-blue-400',
    'whatchefswant'      => 'text-yellow-400',
    'chefswarehouse'     => 'text-orange-400',
    'premiereproduceone' => 'text-purple-400',
  }.freeze

  def brand_color_class
    BRAND_COLORS[code] || 'text-gray-400'
  end

  def short_name
    case code
    when 'usfoods'            then 'US Foods'
    when 'sysco'              then 'Sysco'
    when 'whatchefswant'      then 'WCW'
    when 'chefswarehouse'     then "Chef's WH"
    when 'premiereproduceone' then 'PPO'
    else name.truncate(14)
    end
  end
end
