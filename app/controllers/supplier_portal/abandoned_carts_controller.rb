class SupplierPortal::AbandonedCartsController < SupplierPortal::BaseController
  include DateRangeFilterable

  def index
    load_date_range
    load_stats
    load_table
  end

  def show
    @order = scoped_incomplete_orders
      .includes(order_items: :supplier_product)
      .find(params[:id])
    @customer = @order.organization
    @location = @order.location
    @items_count = @order.order_items.size
  end

  private

  # --- Date range setup ---

  def load_date_range
    @date_range = params[:date_range] || "30d"
    @start_date, @end_date = parse_date_range(@date_range, params[:start_date], params[:end_date])
    @prev_start, @prev_end = previous_period(@start_date, @end_date)
  end

  # --- Filtered query scopes ---

  def filtered_orders
    orders = scoped_incomplete_orders
    orders = apply_date_filter(orders)
    orders = apply_status_filter(orders)
    orders
  end

  def previous_filtered_orders
    orders = scoped_incomplete_orders
    if @prev_start && @prev_end
      orders = orders.where(created_at: @prev_start.beginning_of_day..@prev_end.end_of_day)
    end
    orders = apply_status_filter(orders)
    orders
  end

  def apply_date_filter(orders)
    if @start_date && @end_date
      orders.where(created_at: @start_date.beginning_of_day..@end_date.end_of_day)
    else
      orders
    end
  end

  def apply_status_filter(orders)
    case params[:status_type]
    when "abandoned"
      orders.where(status: "pending").where("orders.created_at < ?", 24.hours.ago)
    when "failed"
      orders.where(status: "failed")
    when "cancelled"
      orders.where(status: "cancelled")
    else
      orders
    end
  end

  # --- Stats ---

  def load_stats
    current = filtered_orders
    prev = previous_filtered_orders

    current_count = current.count
    current_lost = current.sum(:total_amount)
    current_avg = current_count > 0 ? (current_lost.to_f / current_count).round(2) : 0
    current_failed = current.where(status: "failed").count

    prev_count = prev.count
    prev_lost = prev.sum(:total_amount)
    prev_avg = prev_count > 0 ? (prev_lost.to_f / prev_count).round(2) : 0
    prev_failed = prev.where(status: "failed").count

    @stats = {
      count: current_count,
      count_change: percentage_change(current_count, prev_count),
      lost_revenue: current_lost,
      lost_revenue_change: percentage_change(current_lost, prev_lost),
      avg_value: current_avg,
      avg_value_change: percentage_change(current_avg, prev_avg),
      failed_count: current_failed,
      failed_change: percentage_change(current_failed, prev_failed)
    }
  end

  # --- Table ---

  def load_table
    @page = (params[:page] || 1).to_i
    @per_page = 25
    @total_count = filtered_orders.count
    @orders = filtered_orders
      .includes(:organization, :location)
      .order(created_at: :desc)
      .offset((@page - 1) * @per_page)
      .limit(@per_page)
  end

  # --- Nav highlight ---

  def current_portal_section
    "abandoned_carts"
  end
end
