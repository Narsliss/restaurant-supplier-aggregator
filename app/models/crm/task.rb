class Crm::Task < ApplicationRecord
  PRIORITIES = %w[low normal high].freeze

  belongs_to :lead, class_name: "Crm::Lead"
  belongs_to :assigned_to, class_name: "User"

  validates :title, :due_date, presence: true
  validates :priority, inclusion: { in: PRIORITIES }

  scope :pending, -> { where(completed_at: nil) }
  scope :overdue, -> { pending.where("due_date < ?", Date.current) }
  scope :upcoming, -> { pending.where("due_date >= ?", Date.current).order(:due_date) }
  scope :for_user, ->(user) { where(assigned_to: user) }

  def completed?
    completed_at.present?
  end

  def overdue?
    !completed? && due_date < Date.current
  end

  def complete!
    update!(completed_at: Time.current)
  end
end
