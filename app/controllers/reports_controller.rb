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
    orders = scoped_orders.where(created_at: date_range)
    orders = orders.for_location(Location.find(@selected_location_id)) if @selected_location_id.present? && @selected_location_id > 0

    # Summary stats
    @summary = {
      total_spent: orders.sum(:total_amount),
      total_savings: orders.sum(:savings_amount),
      order_count: orders.count,
      avg_order_size: orders.count > 0 ? (orders.sum(:total_amount) / orders.count).round(2) : 0
    }

    # Breakdown by restaurant
    @by_restaurant = @locations.map do |loc|
      loc_orders = orders.for_location(loc)
      {
        location: loc,
        total_spent: loc_orders.sum(:total_amount),
        order_count: loc_orders.count,
        savings: loc_orders.sum(:savings_amount)
      }
    end.sort_by { |r| -r[:total_spent] }

    # Breakdown by supplier
    @by_supplier = orders.includes(:supplier)
      .group(:supplier_id)
      .select("supplier_id, SUM(total_amount) as total_spent, COUNT(*) as order_count, SUM(savings_amount) as savings")
      .map do |row|
        {
          supplier: Supplier.find(row.supplier_id),
          total_spent: row.total_spent,
          order_count: row.order_count,
          savings: row.savings
        }
      end.sort_by { |r| -r[:total_spent] }

    # Breakdown by team member (owners see all, managers see assigned locations)
    @by_member = orders.includes(:user)
      .group(:user_id)
      .select("user_id, SUM(total_amount) as total_spent, COUNT(*) as order_count")
      .map do |row|
        {
          user: User.find(row.user_id),
          total_spent: row.total_spent,
          order_count: row.order_count
        }
      end.sort_by { |r| -r[:total_spent] }

    # Weekly spending trend (last 8 weeks)
    @weekly_trend = (0..7).map do |weeks_ago|
      week_start = (Date.current - weeks_ago.weeks).beginning_of_week
      week_end = week_start.end_of_week
      week_orders = orders.where(created_at: week_start.beginning_of_day..week_end.end_of_day)
      {
        week: week_start,
        label: week_start.strftime("%b %d"),
        total: week_orders.sum(:total_amount),
        count: week_orders.count
      }
    end.reverse
  end
end
