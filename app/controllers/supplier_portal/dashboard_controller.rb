class SupplierPortal::DashboardController < SupplierPortal::BaseController
  include DateRangeFilterable

  def index
    orders = scoped_orders
    products = scoped_products

    # --- Current period (last 30 days) ---
    current_orders = orders.where("submitted_at >= ?", 30.days.ago)
    current_revenue = current_orders.sum(:total_amount)
    current_count = current_orders.count
    current_customers = current_orders.distinct.count(:organization_id)
    current_avg = current_count > 0 ? (current_revenue.to_f / current_count).round(2) : 0

    # --- Prior period (30-60 days ago) ---
    prev_orders = orders.where(submitted_at: 60.days.ago..30.days.ago)
    prev_revenue = prev_orders.sum(:total_amount)
    prev_count = prev_orders.count
    prev_customers = prev_orders.distinct.count(:organization_id)
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

    # --- All-time totals (for context line) ---
    @all_time_orders = orders.count
    @all_time_revenue = orders.sum(:total_amount)

    # --- Catalog health (compact summary) ---
    @product_health = {
      total: products.count,
      in_stock: products.where(in_stock: true, discontinued: false).count,
      out_of_stock: products.where(in_stock: false, discontinued: false).count,
      discontinued: products.where(discontinued: true).count
    }

    # --- Customer reach (compact summary) ---
    connected = SupplierCredential.where(supplier_id: current_supplier.id).count
    total_users = connected + User.where.not(
      id: SupplierCredential.where(supplier_id: current_supplier.id).select(:user_id)
    ).count
    @customer_reach = {
      connected: connected,
      total: total_users,
      rate: total_users > 0 ? (connected.to_f / total_users * 100).round : 0
    }

    # --- Latest order (quick glance) ---
    @latest_order = scoped_orders.includes(:organization).order(submitted_at: :desc).first
  end
end
