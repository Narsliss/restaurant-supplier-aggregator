class EventPlan < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  has_many :messages, class_name: "EventPlanMessage", dependent: :destroy

  validates :status, inclusion: { in: %w[drafting finalized ordered] }

  # Soft delete — deleted plans are hidden from UI but still count toward monthly quota
  default_scope { where(deleted_at: nil) }
  scope :with_deleted, -> { unscope(where: :deleted_at) }
  scope :only_deleted, -> { unscope(where: :deleted_at).where.not(deleted_at: nil) }
  scope :recent, -> { order(updated_at: :desc) }

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def deleted?
    deleted_at.present?
  end

  def finalized?
    status == "finalized"
  end

  def ordered?
    status == "ordered"
  end

  def has_menu?
    current_menu.present? && current_menu["courses"].present?
  end

  def total_cost
    current_menu.dig("cost_summary", "total_cost")
  end

  def cost_per_cover
    current_menu.dig("cost_summary", "cost_per_cover")
  end

  def covers
    event_details["covers"]
  end

  def budget_per_cover
    event_details["budget_per_cover"]
  end

  def wines
    event_details["wines"] || []
  end

  def cuisine_style
    event_details["cuisine_style"]
  end

  def courses
    current_menu["courses"] || []
  end

  def conversation_messages
    messages.order(:created_at)
  end

  def message_count
    messages.where(role: "user").count
  end

  def message_limit
    organization.menu_plan_message_limit
  end

  def messages_remaining
    [message_limit - message_count, 0].max
  end

  def can_send_message?
    message_count < message_limit
  end

  def auto_title!
    return if title.present?

    event_type = event_details["event_type"] || "Event"
    cover_count = covers || "?"
    update!(title: "#{event_type} - #{cover_count} covers")
  end
end
