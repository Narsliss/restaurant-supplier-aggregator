class SupplierDeliverySchedule < ApplicationRecord
  # Associations
  belongs_to :supplier
  belongs_to :location, optional: true

  # Validations
  validates :day_of_week, presence: true, inclusion: { in: 0..6 }
  validates :cutoff_day, presence: true, inclusion: { in: 0..6 }
  validates :cutoff_time, presence: true

  # Scopes
  scope :active, -> { where(active: true) }
  scope :for_day, ->(day) { where(day_of_week: day) }
  scope :for_location, ->(location) { where(location: [location, nil]) }

  # Day names
  DAY_NAMES = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze

  # Methods
  def day_name
    DAY_NAMES[day_of_week]
  end

  def cutoff_day_name
    DAY_NAMES[cutoff_day]
  end

  def next_delivery_date
    today = Date.current
    days_until_delivery = (day_of_week - today.wday) % 7
    days_until_delivery = 7 if days_until_delivery == 0 && past_cutoff?
    today + days_until_delivery
  end

  def next_cutoff_datetime
    delivery_date = next_delivery_date
    days_before_delivery = (day_of_week - cutoff_day) % 7
    cutoff_date = delivery_date - days_before_delivery

    # If cutoff is today and already passed, next cutoff is next week
    if cutoff_date == Date.current && past_cutoff?
      cutoff_date += 7
    end

    Time.zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 
                    cutoff_time.hour, cutoff_time.min)
  end

  def past_cutoff?
    return false unless cutoff_time

    today = Date.current
    return false unless today.wday == cutoff_day

    Time.current.strftime("%H:%M") > cutoff_time.strftime("%H:%M")
  end

  def time_until_cutoff
    cutoff_datetime = next_cutoff_datetime
    return 0 if Time.current > cutoff_datetime
    cutoff_datetime - Time.current
  end

  def cutoff_approaching?(threshold: 1.hour)
    time_until_cutoff > 0 && time_until_cutoff < threshold
  end

  def formatted_schedule
    "Delivers #{day_name}, order by #{cutoff_time.strftime('%I:%M %p')} #{cutoff_day_name}"
  end
end
