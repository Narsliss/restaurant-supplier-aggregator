class SupplierRequirement < ApplicationRecord
  # Associations
  belongs_to :supplier

  # Validations
  validates :requirement_type, presence: true
  validates :error_message, presence: true
  validates :requirement_type, inclusion: { 
    in: %w[order_minimum item_minimum delivery_day cutoff_time service_area max_quantity account_status] 
  }

  # Scopes
  scope :active, -> { where(active: true) }
  scope :blocking, -> { where(is_blocking: true) }
  scope :by_type, ->(type) { where(requirement_type: type) }

  # Requirement types
  TYPES = {
    order_minimum: "order_minimum",
    item_minimum: "item_minimum",
    delivery_day: "delivery_day",
    cutoff_time: "cutoff_time",
    service_area: "service_area",
    max_quantity: "max_quantity",
    account_status: "account_status"
  }.freeze

  # Methods
  def order_minimum?
    requirement_type == "order_minimum"
  end

  def cutoff_time?
    requirement_type == "cutoff_time"
  end

  def blocking?
    is_blocking
  end

  def formatted_error_message(values = {})
    message = error_message.dup
    values.each do |key, value|
      message.gsub!("{{#{key}}}", value.to_s)
    end
    message
  end

  def check(order)
    case requirement_type
    when "order_minimum"
      check_order_minimum(order)
    when "cutoff_time"
      check_cutoff_time(order)
    else
      { passed: true }
    end
  end

  private

  def check_order_minimum(order)
    current_total = order.calculated_subtotal
    minimum = numeric_value

    if current_total >= minimum
      { passed: true }
    else
      {
        passed: false,
        message: formatted_error_message(
          current_total: format_currency(current_total),
          minimum: format_currency(minimum),
          difference: format_currency(minimum - current_total)
        )
      }
    end
  end

  def check_cutoff_time(order)
    schedule = supplier.delivery_schedule_for(order.location).first
    return { passed: true } unless schedule

    cutoff = schedule.next_cutoff_datetime
    
    if Time.current <= cutoff
      { passed: true, warning: Time.current > cutoff - 1.hour ? "Cutoff approaching" : nil }
    else
      {
        passed: false,
        message: formatted_error_message(
          cutoff_time: cutoff.strftime("%I:%M %p"),
          current_time: Time.current.strftime("%I:%M %p")
        )
      }
    end
  end

  def format_currency(amount)
    "$#{'%.2f' % amount}"
  end
end
