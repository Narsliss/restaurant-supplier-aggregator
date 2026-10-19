class Supplier < ApplicationRecord
  # Deleting a supplier takes it out of every matched row first (recorded) —
  # its list items can't be deleted while rows use them. prepend: runs before
  # the dependent destroys below.
  before_destroy(prepend: true) do
    MatchedListSupplierRemoval.new(ProductMatchItem.where(supplier_id: id), cause: 'supplier_deleted').call
  end

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

  # What the morning catalog run does with the supplier's stock answer (plan
  # Phase 3, Oct 2026; see ImportSupplierProductsService#apply_stock_evidence!).
  # live (the default) = mark items out and back in, with a guard that holds a
  # run reading an implausible share out; shadow = record and count only;
  # off = record nothing. Set per supplier on the Operations page.
  MORNING_STOCK_MODES = %w[off shadow live].freeze
  validates :morning_stock_mode, inclusion: { in: MORNING_STOCK_MODES }, if: -> { has_attribute?(:morning_stock_mode) }

  # Code can load before migration 20261019180000 has run: db:migrate itself
  # boots the app (and the supplier seed in config/initializers), and the
  # worker boots before web migrates. Until the columns exist, a supplier
  # reads as "off" with no run recorded, so nothing at boot can fail on them.
  def morning_stock_mode
    has_attribute?(:morning_stock_mode) ? super : 'off'
  end

  def last_stock_run
    has_attribute?(:last_stock_run) ? super : nil
  end

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

  # Indicates whether this supplier exposes an API we can use to discover
  # which delivery dates are valid for the customer. Returns :api when we
  # have an integration, nil when we don't. Used to gate delivery schedule
  # UI so we only show it for suppliers where it means something.
  def delivery_dates_source
    case code
    when 'sysco', 'performance' then :api
    end
  end

  def api_delivery_dates?
    delivery_dates_source == :api
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

  # US Foods fills from stock on the way, so an item it shows at 0 only
  # warns (Carmin's D1, Oct 19 2026). Everywhere else an item the supplier
  # calls out can't be ordered. One rule for the review page and both order
  # builders.
  def out_of_stock_warns_only?
    return @out_of_stock_warns_only if defined?(@out_of_stock_warns_only)

    @out_of_stock_warns_only =
      if scraper_class.blank?
        false
      else
        klass = scraper_klass
        klass.respond_to?(:warn_only_out_of_stock?) && klass.warn_only_out_of_stock? ? true : false
      end
  rescue NameError
    @out_of_stock_warns_only = false
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
    'usfoods'            => 'text-red-600',
    'sysco'              => 'text-blue-700',
    'whatchefswant'      => 'text-yellow-600',
    'chefswarehouse'     => 'text-orange-600',
    'premiereproduceone' => 'text-purple-600',
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
