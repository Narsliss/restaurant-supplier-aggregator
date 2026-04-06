class Crm::Onboarding < ApplicationRecord
  STAGES = %w[signed_up account_setup suppliers_connected first_order
              check_in_14 check_in_30 check_in_60 check_in_90 complete].freeze
  HEALTH_SCORES = %w[green yellow red].freeze

  HEALTH_COLORS = {
    "green" => "bg-green-100 text-green-800",
    "yellow" => "bg-yellow-100 text-yellow-800",
    "red" => "bg-red-100 text-red-800"
  }.freeze

  STAGE_LABELS = {
    "signed_up" => "Signed Up",
    "account_setup" => "Account Setup",
    "suppliers_connected" => "Suppliers Connected",
    "first_order" => "First Order Placed",
    "check_in_14" => "14-Day Check-in",
    "check_in_30" => "30-Day Check-in",
    "check_in_60" => "60-Day Check-in",
    "check_in_90" => "90-Day Check-in",
    "complete" => "Complete"
  }.freeze

  belongs_to :lead, class_name: "Crm::Lead"
  belongs_to :organization

  validates :stage, inclusion: { in: STAGES }
  validates :health_score, inclusion: { in: HEALTH_SCORES }

  def stage_label
    STAGE_LABELS[stage] || stage.titleize
  end

  def health_color
    HEALTH_COLORS[health_score] || "bg-gray-100 text-gray-800"
  end

  def milestone_timestamps
    STAGES.map do |s|
      ts_col = "#{s}_at"
      [s, respond_to?(ts_col) ? send(ts_col) : nil]
    end
  end
end
