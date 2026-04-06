class Crm::Lead < ApplicationRecord
  PIPELINE_STAGES = %w[lead qualified demo_scheduled demo_completed
                       trial_onboarding closed_won closed_lost].freeze
  VOLUME_OPTIONS = %w[small mid high].freeze

  STAGE_LABELS = {
    "lead" => "Lead",
    "qualified" => "Qualified",
    "demo_scheduled" => "Demo Scheduled",
    "demo_completed" => "Demo Completed",
    "trial_onboarding" => "Trial / Onboarding",
    "closed_won" => "Closed Won",
    "closed_lost" => "Closed Lost"
  }.freeze

  STAGE_COLORS = {
    "lead" => "bg-gray-100 text-gray-800",
    "qualified" => "bg-blue-100 text-blue-800",
    "demo_scheduled" => "bg-indigo-100 text-indigo-800",
    "demo_completed" => "bg-purple-100 text-purple-800",
    "trial_onboarding" => "bg-yellow-100 text-yellow-800",
    "closed_won" => "bg-green-100 text-green-800",
    "closed_lost" => "bg-red-100 text-red-800"
  }.freeze

  belongs_to :salesperson, class_name: "User"
  belongs_to :organization, optional: true

  has_many :activities, class_name: "Crm::Activity", dependent: :destroy
  has_many :tasks, class_name: "Crm::Task", dependent: :destroy
  has_one  :onboarding, class_name: "Crm::Onboarding", dependent: :destroy
  has_many :lead_tags, class_name: "Crm::LeadTag", dependent: :destroy
  has_many :tags, through: :lead_tags, class_name: "Crm::Tag"

  validates :restaurant_name, :contact_name, presence: true
  validates :pipeline_stage, inclusion: { in: PIPELINE_STAGES }
  validates :estimated_volume, inclusion: { in: VOLUME_OPTIONS }, allow_blank: true

  scope :in_stage, ->(stage) { where(pipeline_stage: stage) }
  scope :open_deals, -> { where.not(pipeline_stage: %w[closed_won closed_lost]) }
  scope :for_salesperson, ->(user) { where(salesperson: user) }

  def stage_label
    STAGE_LABELS[pipeline_stage] || pipeline_stage.titleize
  end

  def stage_color
    STAGE_COLORS[pipeline_stage] || "bg-gray-100 text-gray-800"
  end

  def deal_value_dollars
    deal_value_cents.to_f / 100
  end

  def deal_value_dollars=(val)
    self.deal_value_cents = (val.to_f * 100).round
  end

  def won?
    pipeline_stage == "closed_won"
  end

  def lost?
    pipeline_stage == "closed_lost"
  end

  def active?
    !won? && !lost?
  end

  def days_in_stage
    (Date.current - (updated_at || created_at).to_date).to_i
  end

  def last_activity_at
    activities.maximum(:occurred_at)
  end

  def convert_to_organization!
    return unless won?
    return if organization.present?

    org = Organization.create!(
      name: restaurant_name,
      city: city,
      state: state
    )
    update!(organization: org)

    Crm::Onboarding.create!(
      lead: self,
      organization: org,
      stage: "signed_up",
      signed_up_at: Time.current
    )
    org
  end
end
