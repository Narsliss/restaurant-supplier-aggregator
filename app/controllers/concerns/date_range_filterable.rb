module DateRangeFilterable
  extend ActiveSupport::Concern

  private

  # Parse a date range selector value into [start_date, end_date].
  # Returns [nil, nil] when no range is selected ("all time").
  def parse_date_range(range, custom_start = nil, custom_end = nil)
    case range
    when "7d"     then [7.days.ago.to_date, Date.current]
    when "30d"    then [30.days.ago.to_date, Date.current]
    when "90d"    then [90.days.ago.to_date, Date.current]
    when "ytd"    then [Date.current.beginning_of_year, Date.current]
    when "custom"
      start_d = Date.parse(custom_start) rescue nil
      end_d = Date.parse(custom_end) rescue nil
      [start_d, end_d]
    else [nil, nil]
    end
  end

  # Given the current period's [start_date, end_date], compute the
  # equally-sized prior period for comparison.
  def previous_period(start_date, end_date)
    if start_date && end_date
      days = (end_date - start_date).to_i
      prev_end = start_date - 1.day
      prev_start = prev_end - days.days + 1.day
      [prev_start, prev_end]
    else
      [60.days.ago.to_date, 31.days.ago.to_date]
    end
  end

  # Percentage change helper — returns nil when previous is zero.
  def percentage_change(current, previous)
    return nil if previous.nil? || previous.zero?
    ((current - previous).to_f / previous * 100).round(1)
  end
end
