class Location < ApplicationRecord
  # Associations — locations are now org-owned ("restaurants")
  belongs_to :organization
  belongs_to :user, optional: true           # Legacy: kept for backward compat
  belongs_to :created_by, class_name: 'User', optional: true

  has_many :membership_locations, dependent: :destroy
  has_many :memberships, through: :membership_locations
  has_many :supplier_credentials, dependent: :nullify
  has_many :supplier_lists, dependent: :nullify
  has_many :supplier_delivery_schedules, dependent: :destroy
  has_many :orders, dependent: :nullify
  has_many :order_lists, dependent: :nullify

  # Validations
  validates :name, presence: true
  validates :name, uniqueness: { scope: :organization_id }
  validates :address, :city, :state, :zip_code, presence: true

  # Scopes
  scope :default_first, -> { order(is_default: :desc, created_at: :asc) }

  # Methods
  def full_address
    [address, city, state, zip_code].map(&:presence).compact.join(", ")
  end

  def assigned_members
    memberships.where(active: true).includes(:user)
  end
end
