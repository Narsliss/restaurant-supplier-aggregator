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
  has_many :supplier_requirements, dependent: :destroy
  has_many :orders, dependent: :nullify
  has_many :order_lists, dependent: :nullify

  # Validations
  validates :name, presence: true
  validates :name, uniqueness: { scope: :organization_id }
  validates :address, :city, :state, :zip_code, presence: true

  # Scopes
  scope :default_first, -> { order(is_default: :desc, created_at: :asc) }

  # Callbacks
  after_create_commit :create_default_matched_list

  # Methods
  def full_address
    [address, city, state, zip_code].map(&:presence).compact.join(", ")
  end

  def assigned_members
    memberships.where(active: true).includes(:user)
  end

  private

  # Each location automatically gets its own "matched" AggregatedList so chefs
  # assigned to a single restaurant land on a real (if empty) list instead of
  # a blank Product Matching page. Org-wide promoted lists can still override.
  def create_default_matched_list
    creator = created_by || organization&.owner
    return unless creator && organization

    organization.aggregated_lists.create!(
      location_id: id,
      created_by: creator,
      name: "#{name} Matched List",
      list_type: "matched",
      match_status: "pending"
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[Location##{id}] default matched list create failed: #{e.message}")
  end
end
