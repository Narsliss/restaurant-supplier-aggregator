class Crm::Tag < ApplicationRecord
  TAG_COLORS = %w[gray blue green yellow red purple indigo pink].freeze

  has_many :lead_tags, class_name: "Crm::LeadTag", dependent: :destroy
  has_many :leads, through: :lead_tags, class_name: "Crm::Lead"

  validates :name, presence: true, uniqueness: true
  validates :color, inclusion: { in: TAG_COLORS }
end
