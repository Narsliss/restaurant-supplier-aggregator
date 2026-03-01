class EventPlanMessage < ApplicationRecord
  belongs_to :event_plan, touch: true

  validates :role, inclusion: { in: %w[user assistant] }
  validates :content, presence: true
  validates :status, inclusion: { in: %w[complete thinking error] }

  scope :chronological, -> { order(:created_at) }

  def user?
    role == "user"
  end

  def assistant?
    role == "assistant"
  end

  def thinking?
    status == "thinking"
  end

  def error?
    status == "error"
  end

  def has_menu_data?
    structured_data.present? && structured_data["courses"].present?
  end
end
