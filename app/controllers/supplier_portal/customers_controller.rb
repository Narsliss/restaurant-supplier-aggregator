require "ostruct"

class SupplierPortal::CustomersController < SupplierPortal::BaseController
  def index
    # Build customer data from orders grouped by organization
    customers_data = scoped_orders
      .joins(:organization)
      .group(:organization_id)
      .select(
        "orders.organization_id",
        "COUNT(*) AS order_count",
        "SUM(orders.total_amount) AS total_revenue",
        "AVG(orders.total_amount) AS avg_order_value",
        "MAX(orders.submitted_at) AS last_order_at",
        "COUNT(DISTINCT orders.location_id) AS location_count"
      )
      .order(Arel.sql("SUM(orders.total_amount) DESC"))

    # Search by organization name
    if params[:q].present?
      customers_data = customers_data.where("organizations.name ILIKE ?", "%#{params[:q]}%")
    end

    # Churn filter
    case params[:churn]
    when "active"
      customers_data = customers_data.having("MAX(orders.submitted_at) >= ?", 30.days.ago)
    when "at_risk"
      customers_data = customers_data.having("MAX(orders.submitted_at) < ? AND MAX(orders.submitted_at) >= ?", 30.days.ago, 60.days.ago)
    when "churned"
      customers_data = customers_data.having("MAX(orders.submitted_at) < ?", 60.days.ago)
    end

    # Top-level stats
    @total_customers = scoped_orders.distinct.count(:organization_id)
    @total_revenue = scoped_orders.sum(:total_amount)
    @active_customers = scoped_orders.where("submitted_at >= ?", 30.days.ago).distinct.count(:organization_id)
    @at_risk_count = scoped_orders
      .group(:organization_id)
      .having("MAX(submitted_at) < ? AND MAX(submitted_at) >= ?", 30.days.ago, 60.days.ago)
      .count.size

    # Pagination
    @page = (params[:page] || 1).to_i
    @per_page = 25
    all_results = customers_data.to_a
    @total_count = all_results.size

    paged = all_results.slice((@page - 1) * @per_page, @per_page) || []
    org_ids = paged.map(&:organization_id)
    orgs_by_id = Organization.where(id: org_ids).index_by(&:id)

    @customers = paged.map do |row|
      org = orgs_by_id[row.organization_id]
      next unless org
      OpenStruct.new(
        organization: org,
        order_count: row.order_count,
        total_revenue: row.total_revenue.to_f,
        avg_order_value: row.avg_order_value.to_f,
        last_order_at: row.last_order_at,
        location_count: row.location_count,
        churn_status: churn_status_for(row.last_order_at)
      )
    end.compact
  end

  def show
    @organization = Organization.joins(:orders)
                                .where(orders: { supplier_id: current_supplier.id })
                                .distinct
                                .find(params[:id])
    org_orders = scoped_orders.where(organization_id: @organization.id)
    raise ActiveRecord::RecordNotFound if org_orders.none?

    @stats = {
      total_revenue: org_orders.sum(:total_amount),
      order_count: org_orders.count,
      avg_order_value: org_orders.count > 0 ? (org_orders.sum(:total_amount).to_f / org_orders.count).round(2) : 0,
      last_order_at: org_orders.maximum(:submitted_at),
      location_count: org_orders.distinct.count(:location_id),
      first_order_at: org_orders.minimum(:submitted_at)
    }

    # Weekly charts (90 days)
    @weekly_orders = org_orders
      .where("submitted_at >= ?", 90.days.ago)
      .group(Arel.sql("date_trunc('week', submitted_at)::date"))
      .order(Arel.sql("date_trunc('week', submitted_at)::date"))
      .count

    @weekly_revenue = org_orders
      .where("submitted_at >= ?", 90.days.ago)
      .group(Arel.sql("date_trunc('week', submitted_at)::date"))
      .order(Arel.sql("date_trunc('week', submitted_at)::date"))
      .sum(:total_amount)

    # Top 20 products
    @top_products = scoped_order_items
      .joins(:order)
      .where(orders: { organization_id: @organization.id })
      .joins(:supplier_product)
      .group("supplier_products.id", "supplier_products.supplier_name", "supplier_products.supplier_sku")
      .select(
        "supplier_products.id AS product_id",
        "supplier_products.supplier_name AS product_name",
        "supplier_products.supplier_sku AS sku",
        "SUM(order_items.quantity) AS total_qty",
        "SUM(order_items.line_total) AS total_revenue",
        "COUNT(DISTINCT orders.id) AS order_count"
      )
      .order(Arel.sql("SUM(order_items.line_total) DESC"))
      .limit(20)

    # Location breakdown
    @locations = org_orders
      .joins(:location)
      .group("locations.id", "locations.name", "locations.city", "locations.state")
      .select(
        "locations.id AS location_id",
        "locations.name AS location_name",
        "locations.city",
        "locations.state",
        "COUNT(*) AS order_count",
        "SUM(orders.total_amount) AS total_revenue",
        "MAX(orders.submitted_at) AS last_order_at"
      )
      .order(Arel.sql("SUM(orders.total_amount) DESC"))

    # Recent orders
    @recent_orders = org_orders
      .includes(:location)
      .order(submitted_at: :desc)
      .limit(10)
  end

  private

  def churn_status_for(last_order_at)
    return "churned" if last_order_at.nil? || last_order_at < 60.days.ago
    return "at_risk" if last_order_at < 30.days.ago
    "active"
  end
end
