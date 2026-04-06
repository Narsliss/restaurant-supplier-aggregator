class Crm::Activity < ApplicationRecord
  TYPES = %w[call email note meeting].freeze

  TYPE_ICONS = {
    "call" => "phone",
    "email" => "envelope",
    "note" => "pencil",
    "meeting" => "users"
  }.freeze

  belongs_to :lead, class_name: "Crm::Lead"
  belongs_to :user

  validates :activity_type, inclusion: { in: TYPES }
  validates :occurred_at, presence: true

  scope :recent, -> { order(occurred_at: :desc) }

  def type_label
    activity_type.capitalize
  end
end
