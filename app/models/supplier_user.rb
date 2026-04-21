class SupplierUser < ApplicationRecord
  devise :database_authenticatable, :recoverable, :rememberable,
         :validatable, :trackable, :lockable, :timeoutable

  belongs_to :supplier

  ROLES = %w[admin rep].freeze

  validates :first_name, presence: true
  validates :last_name, presence: true
  validates :role, presence: true, inclusion: { in: ROLES }

  scope :active, -> { where(active: true) }
  scope :admins, -> { where(role: "admin") }
  scope :reps, -> { where(role: "rep") }

  def admin?
    role == "admin"
  end

  def rep?
    role == "rep"
  end

  def full_name
    [first_name, last_name].compact.join(" ").presence || email
  end

  def initials
    [first_name&.first, last_name&.first].compact.join.upcase.presence || email.first.upcase
  end
end
