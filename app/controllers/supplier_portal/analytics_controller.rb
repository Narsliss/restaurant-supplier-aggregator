class SupplierPortal::AnalyticsController < SupplierPortal::BaseController
  include DateRangeFilterable

  def show
    load_date_range
    load_overview_stats
    load_weekly_charts
  end

  def revenue
    load_date_range
    load_revenue_by_customer
    load_revenue_by_location
    load_revenue_by_day_of_week
  end

  def products
    load_top_sellers
    load_trending_up
    load_trending_down
    load_never_ordered
  end

  private

  # --- Shared date range setup ---

  def load_date_range
    @date_range = params[:date_range] || "30d"
    @start_date, @end_date = parse_date_range(@date_range, params[:start_date], params[:end_date])
    @prev_start, @prev_end = previous_period(@start_date, @end_date)

    # If "all time" (nil dates), default to 30d for charts
    @effective_start = @start_date || 30.days.ago.to_date
    @effective_end = @end_date || Date.current
  end

  def filtered_orders
    orders = scoped_orders
    if @start_date && @end_date
      orders = orders.where(submitted_at: @start_date.beginning_of_day..@end_date.end_of_day)
    end
    orders
  end

  def previous_orders
    scoped_orders.where(submitted_at: @prev_start.beginning_of_day..@prev_end.end_of_day)
  end

  # --- Overview (show) ---

  def load_overview_stats
    current = filtered_orders
    prev = previous_orders

    current_revenue = current.sum(:total_amount)
    current_count = current.count
    current_customers = current.distinct.count(:organization_id)
    current_avg = current_count > 0 ? (current_revenue.to_f / current_count).round(2) : 0

    prev_revenue = prev.sum(:total_amount)
    prev_count = prev.count
    prev_customers = prev.distinct.count(:organization_id)
    prev_avg = prev_count > 0 ? (prev_revenue.to_f / prev_count).round(2) : 0

    @stats = {
      revenue: current_revenue,
      revenue_change: percentage_change(current_revenue, prev_revenue),
      orders: current_count,
      orders_change: percentage_change(current_count, prev_count),
      avg_value: current_avg,
      avg_value_change: percentage_change(current_avg, prev_avg),
      customers: current_customers,
      customers_change: percentage_change(current_customers, prev_customers)
    }
  end

  def load_weekly_charts
    base = scoped_orders.where(submitted_at: @effective_start.beginning_of_day..@effective_end.end_of_day)

    @weekly_revenue = base
      .group(Arel.sql("date_trunc('week', submitted_at)::date"))
      .order(Arel.sql("date_trunc('week', submitted_at)::date"))
      .sum(:total_amount)

    @weekly_orders = base
      .group(Arel.sql("date_trunc('week', submitted_at)::date"))
      .order(Arel.sql("date_trunc('week', submitted_at)::date"))
      .count
  end

  # --- Revenue ---

  def load_revenue_by_customer
    @revenue_by_customer = filtered_orders
      .joins(:organization)
      .group(:organization_id, "organizations.name")
      .select(
        "orders.organization_id",
        "organizations.name AS customer_name",
        "SUM(orders.total_amount) AS total_revenue",
        "COUNT(*) AS order_count"
      )
      .order(Arel.sql("SUM(orders.total_amount) DESC"))
      .limit(15)
  end

  def load_revenue_by_location
    @revenue_by_location = filtered_orders
      .joins(:location)
      .group("locations.id", "locations.name", "locations.city", "locations.state")
      .select(
        "locations.id AS location_id",
        "locations.name AS location_name",
        "locations.city",
        "locations.state",
        "SUM(orders.total_amount) AS total_revenue",
        "COUNT(*) AS order_count"
      )
      .order(Arel.sql("SUM(orders.total_amount) DESC"))
      .limit(15)
  end

  def load_revenue_by_day_of_week
    # PostgreSQL EXTRACT(ISODOW): 1=Monday..7=Sunday
    raw = filtered_orders
      .group(Arel.sql("EXTRACT(ISODOW FROM submitted_at)::integer"))
      .select(
        Arel.sql("EXTRACT(ISODOW FROM submitted_at)::integer AS dow"),
        Arel.sql("AVG(total_amount) AS avg_revenue"),
        Arel.sql("COUNT(*) AS order_count")
      )

    @day_of_week_data = (1..7).map do |dow|
      row = raw.find { |r| r.dow == dow }
      {
        label: Date::DAYNAMES[dow % 7],
        short_label: Date::ABBR_DAYNAMES[dow % 7],
        avg_revenue: row&.avg_revenue&.to_f&.round(2) || 0,
        order_count: row&.order_count || 0
      }
    end
  end

  # --- Product Performance ---

  def load_top_sellers
    @top_sellers = scoped_order_items
      .joins(:order)
      .where("orders.submitted_at >= ?", 30.days.ago)
      .joins(:supplier_product)
      .group("supplier_products.id", "supplier_products.supplier_name", "supplier_products.supplier_sku")
      .select(
        "supplier_products.id AS product_id",
        "supplier_products.supplier_name AS product_name",
        "supplier_products.supplier_sku AS sku",
        "SUM(order_items.line_total) AS total_revenue",
        "SUM(order_items.quantity) AS total_qty",
        "COUNT(DISTINCT orders.id) AS order_frequency",
        "CASE WHEN COUNT(DISTINCT orders.id) > 0
              THEN SUM(order_items.quantity)::float / COUNT(DISTINCT orders.id)
              ELSE 0 END AS avg_qty_per_order"
      )
      .order(Arel.sql("SUM(order_items.line_total) DESC"))
      .limit(20)
  end

  def load_trending_up
    @trending_up = products_with_trend_change.select { |p| p[:change] > 0 }
      .sort_by { |p| -p[:change] }
      .first(15)
  end

  def load_trending_down
    @trending_down = products_with_trend_change.select { |p| p[:change] < 0 }
      .sort_by { |p| p[:change] }
      .first(15)
  end

  def load_never_ordered
    ordered_product_ids = scoped_order_items
      .joins(:order)
      .where("orders.submitted_at >= ?", 90.days.ago)
      .distinct
      .pluck(:supplier_product_id)

    @never_ordered = scoped_products
      .available
      .where.not(id: ordered_product_ids)
      .order(:supplier_name)
      .limit(50)
  end

  def products_with_trend_change
    @_products_with_trend ||= begin
      current_period = scoped_order_items
        .joins(:order)
        .where("orders.submitted_at >= ?", 30.days.ago)
        .joins(:supplier_product)
        .group("supplier_products.id", "supplier_products.supplier_name", "supplier_products.supplier_sku")
        .select(
          "supplier_products.id AS product_id",
          "supplier_products.supplier_name AS product_name",
          "supplier_products.supplier_sku AS sku",
          "SUM(order_items.quantity) AS current_qty"
        )

      prev_period = scoped_order_items
        .joins(:order)
        .where(orders: { submitted_at: 60.days.ago..30.days.ago })
        .joins(:supplier_product)
        .group(:supplier_product_id)
        .sum(:quantity)

      current_period.filter_map do |product|
        prev_qty = prev_period[product.product_id] || 0
        current_qty = product.current_qty.to_i
        next if current_qty.zero? && prev_qty.zero?

        change_pct = if prev_qty.zero?
          current_qty > 0 ? 100.0 : 0.0
        else
          ((current_qty - prev_qty).to_f / prev_qty * 100).round(1)
        end

        next if change_pct.zero?

        {
          product_id: product.product_id,
          product_name: product.product_name,
          sku: product.sku,
          current_qty: current_qty,
          prev_qty: prev_qty,
          change: change_pct
        }
      end
    end
  end
end
