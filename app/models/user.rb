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
end
