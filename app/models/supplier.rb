class Supplier < ApplicationRecord
  # Associations
  has_many :supplier_credentials, dependent: :destroy
  has_many :users, through: :supplier_credentials
  has_many :supplier_products, dependent: :destroy
  has_many :products, through: :supplier_products
  has_many :supplier_requirements, dependent: :destroy
  has_many :supplier_delivery_schedules, dependent: :destroy
  has_many :orders, dependent: :restrict_with_error

  # Validations
  validates :name, presence: true
  validates :code, presence: true, uniqueness: true
  validates :base_url, presence: true
  validates :login_url, presence: true
  validates :scraper_class, presence: true

  # Scopes
  scope :active, -> { where(active: true) }
  scope :by_name, -> { order(:name) }

  # Methods
  def scraper_klass
    scraper_class.constantize
  end

  def order_minimum
    supplier_requirements.find_by(requirement_type: "order_minimum", active: true)&.numeric_value
  end

  def cutoff_requirement
    supplier_requirements.find_by(requirement_type: "cutoff_time", active: true)
  end

  def delivery_schedule_for(location)
    supplier_delivery_schedules.where(location: [location, nil], active: true)
  end

  def product_by_sku(sku)
    supplier_products.find_by(supplier_sku: sku)
  end
end
