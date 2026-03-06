class SupplierPortal::ProductsController < SupplierPortal::BaseController
  def index
    @products = scoped_products

    # Search
    if params[:q].present?
      @products = @products.where("supplier_name ILIKE ?", "%#{params[:q]}%")
    end

    # Filters
    case params[:filter]
    when "in_stock"
      @products = @products.available.in_stock
    when "out_of_stock"
      @products = @products.available.out_of_stock
    when "discontinued"
      @products = @products.discontinued
    when "price_changed"
      @products = @products.price_changed
    else
      # Default: show all active (non-discontinued)
      @products = @products.available unless params[:filter] == "all"
    end

    # Stats for the filter bar
    @product_stats = {
      total: scoped_products.count,
      active: scoped_products.available.count,
      in_stock: scoped_products.available.in_stock.count,
      out_of_stock: scoped_products.available.out_of_stock.count,
      discontinued: scoped_products.discontinued.count,
      price_changed: scoped_products.price_changed.count
    }

    # Pagination
    @page = (params[:page] || 1).to_i
    @per_page = 50
    @total_count = @products.count
    @products = @products.order(:supplier_name).offset((@page - 1) * @per_page).limit(@per_page)
  end

  def show
    @product = scoped_products.find(params[:id])

    # Weekly order history for this product
    @order_history = OrderItem
      .joins(:order)
      .where(supplier_product_id: @product.id)
      .where(orders: { status: %w[submitted confirmed] })
      .where("orders.submitted_at >= ?", 90.days.ago)
      .group(Arel.sql("date_trunc('week', orders.submitted_at)"))
      .pluck(
        Arel.sql("date_trunc('week', orders.submitted_at)"),
        Arel.sql("SUM(order_items.quantity)"),
        Arel.sql("SUM(order_items.line_total)")
      )
      .map { |w, q, r| { week: w.to_date, quantity: q.to_f, revenue: r.to_f } }
      .sort_by { |r| r[:week] }

    # Total stats for this product
    all_items = OrderItem
      .joins(:order)
      .where(supplier_product_id: @product.id)
      .where(orders: { status: %w[submitted confirmed] })

    @product_stats = {
      total_orders: all_items.distinct.count("orders.id"),
      total_quantity: all_items.sum(:quantity),
      total_revenue: all_items.sum(:line_total),
      unique_customers: Order.joins(:order_items)
        .where(order_items: { supplier_product_id: @product.id })
        .where(status: %w[submitted confirmed])
        .distinct.count(:organization_id)
    }
  end

  def health
    base = scoped_products

    @out_of_stock = base.available.out_of_stock.order(:supplier_name).limit(50)
    @discontinued = base.discontinued.order(discontinued_at: :desc).limit(50)
    @at_risk = base.at_risk.order(consecutive_misses: :desc).limit(50)
    @stale = base.available.stale.order(:last_scraped_at).limit(50)

    @health_stats = {
      out_of_stock: base.available.out_of_stock.count,
      discontinued: base.discontinued.count,
      at_risk: base.at_risk.count,
      stale: base.available.stale.count
    }

    # For stacked health bar
    @total_products = base.count
    @in_stock_count = base.available.in_stock.count
  end
end
