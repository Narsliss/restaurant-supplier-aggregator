class ReportsController < ApplicationController
  before_action :require_organization!
  before_action :require_owner_or_manager!

  def index
    org = current_user.current_organization
    @locations = accessible_locations

    # Date range filter
    @start_date = params[:start_date]&.to_date || 30.days.ago.to_date
    @end_date = params[:end_date]&.to_date || Date.current
    date_range = @start_date.beginning_of_day..@end_date.end_of_day

    # Location filter
    @selected_location_id = params[:location_id]&.to_i
    # Only count orders that were actually submitted to suppliers (kpi_eligible)
    orders = scoped_orders.kpi_eligible.where(created_at: date_range)
    orders = orders.for_location(Location.find(@selected_location_id)) if @selected_location_id.present? && @selected_location_id > 0

    # Summary stats — single query with multiple aggregations
    summary_row = orders.pick(
      Arel.sql("COALESCE(SUM(total_amount), 0)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)"),
      Arel.sql("COUNT(*)"),
      Arel.sql("CASE WHEN COUNT(*) > 0 THEN ROUND(SUM(total_amount) / COUNT(*), 2) ELSE 0 END")
    )
    @summary = {
      total_spent: summary_row[0],
      total_savings: summary_row[1],
      order_count: summary_row[2],
      avg_order_size: summary_row[3]
    }

    # Breakdown by restaurant — single grouped query instead of N queries per location
    location_stats = orders.where(location_id: @locations.select(:id))
      .group(:location_id)
      .pluck(
        Arel.sql("location_id"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(savings_amount), 0)")
      ).index_by(&:first)
    locations_by_id = @locations.index_by(&:id)

    @by_restaurant = @locations.map do |loc|
      row = location_stats[loc.id]
      {
        location: loc,
        total_spent: row ? row[1] : 0,
        order_count: row ? row[2] : 0,
        savings: row ? row[3] : 0
      }
    end.sort_by { |r| -r[:total_spent] }

    # Breakdown by supplier — pre-load suppliers to avoid N+1
    supplier_rows = orders.group(:supplier_id)
      .pluck(
        Arel.sql("supplier_id"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(savings_amount), 0)")
      )
    suppliers_by_id = Supplier.where(id: supplier_rows.map(&:first)).index_by(&:id)

    @by_supplier = supplier_rows.map do |row|
      {
        supplier: suppliers_by_id[row[0]],
        total_spent: row[1],
        order_count: row[2],
        savings: row[3]
      }
    end.sort_by { |r| -r[:total_spent] }

    # Breakdown by team member — pre-load users to avoid N+1
    member_rows = orders.group(:user_id)
      .pluck(
        Arel.sql("user_id"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)")
      )
    users_by_id = User.where(id: member_rows.map(&:first)).index_by(&:id)

    @by_member = member_rows.map do |row|
      {
        user: users_by_id[row[0]],
        total_spent: row[1],
        order_count: row[2]
      }
    end.sort_by { |r| -r[:total_spent] }

    # Weekly spending trend — single grouped query using date_trunc
    eight_weeks_ago = 8.weeks.ago.beginning_of_week.beginning_of_day
    weekly_data = orders.where("orders.created_at >= ?", eight_weeks_ago)
      .group(Arel.sql("date_trunc('week', orders.created_at)"))
      .pluck(
        Arel.sql("date_trunc('week', orders.created_at)"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)")
      ).index_by { |row| row[0].to_date }

    @weekly_trend = (0..7).map do |weeks_ago|
      week_start = (Date.current - weeks_ago.weeks).beginning_of_week
      row = weekly_data[week_start]
      {
        week: week_start,
        label: week_start.strftime("%b %d"),
        total: row ? row[1] : 0,
        count: row ? row[2] : 0
      }
    end.reverse
  end
end
