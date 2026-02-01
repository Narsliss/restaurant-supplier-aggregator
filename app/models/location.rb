class Location < ApplicationRecord
  # Associations
  belongs_to :user
  has_many :supplier_delivery_schedules, dependent: :destroy
  has_many :orders, dependent: :nullify

  # Validations
  validates :name, presence: true
  validates :name, uniqueness: { scope: :user_id }

  # Callbacks
  before_save :ensure_single_default
  after_create :set_as_default_if_first

  # Scopes
  scope :default_first, -> { order(is_default: :desc, created_at: :asc) }

  # Methods
  def full_address
    [address, city, state, zip_code].compact.join(", ")
  end

  def set_as_default!
    transaction do
      user.locations.where.not(id: id).update_all(is_default: false)
      update!(is_default: true)
    end
  end

  private

  def ensure_single_default
    if is_default? && is_default_changed?
      user.locations.where.not(id: id).update_all(is_default: false)
    end
  end

  def set_as_default_if_first
    set_as_default! if user.locations.count == 1
  end
end
