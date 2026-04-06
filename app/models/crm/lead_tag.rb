class Crm::LeadTag < ApplicationRecord
  belongs_to :lead, class_name: "Crm::Lead"
  belongs_to :tag, class_name: "Crm::Tag"

  validates :tag_id, uniqueness: { scope: :lead_id }
end
