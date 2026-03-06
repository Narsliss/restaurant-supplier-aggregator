class SupplierPortal::OrdersController < SupplierPortal::BaseController
  include DateRangeFilterable
  def index
    @orders = scoped_orders.includes(:organization, :location)

    # Search by organization name or confirmation number
    if params[:q].present?
      @orders = @orders.joins(:organization)
        .where("organizations.name ILIKE :q OR orders.confirmation_number ILIKE :q", q: "%#{params[:q]}%")
    end

    # Status filter
    if params[:status].present? && %w[submitted confirmed].include?(params[:status])
      @orders = @orders.where(status: params[:status])
    end

    # Date range filter
    @start_date, @end_date = parse_date_range(params[:date_range], params[:start_date], params[:end_date])
    if @start_date && @end_date
      @orders = @orders.where(submitted_at: @start_date.beginning_of_day..@end_date.end_of_day)
    end

    # Stats for the top cards (computed before pagination)
    filtered_ids = @orders.reorder(nil).select(:id)
    @order_stats = {
      count: @orders.count,
      revenue: @orders.sum(:total_amount),
      avg_value: @orders.count > 0 ? (@orders.sum(:total_amount).to_f / @orders.count).round(2) : 0,
      items: OrderItem.where(order_id: filtered_ids).sum(:quantity).to_i
    }

    # Pagination
    @page = (params[:page] || 1).to_i
    @per_page = 25
    @total_count = @order_stats[:count]
    @orders = @orders.order(submitted_at: :desc).offset((@page - 1) * @per_page).limit(@per_page)
  end

  def show
    @order = scoped_orders.includes(order_items: :supplier_product).find(params[:id])
    @customer = @order.organization
    @location = @order.location

    # Context from this customer
    if @customer
      @related_orders_count = scoped_orders.where(organization_id: @customer.id).count
      @customer_total_revenue = scoped_orders.where(organization_id: @customer.id).sum(:total_amount)
    else
      @related_orders_count = 0
      @customer_total_revenue = 0
    end
  end

  def export
    orders = scoped_orders.includes(:organization, :location, order_items: :supplier_product)

    # Apply same filters
    start_date, end_date = parse_date_range(params[:date_range], params[:start_date], params[:end_date])
    if start_date && end_date
      orders = orders.where(submitted_at: start_date.beginning_of_day..end_date.end_of_day)
    end

    if params[:status].present? && %w[submitted confirmed].include?(params[:status])
      orders = orders.where(status: params[:status])
    end

    orders = orders.order(submitted_at: :desc).limit(5000)

    csv_data = generate_csv(orders)
    send_data csv_data, filename: "orders-#{Date.current}.csv", type: "text/csv"
  end

  private

  def generate_csv(orders)
    require "csv"
    CSV.generate do |csv|
      csv << ["Order ID", "Date", "Customer", "Location", "Status", "Items", "Subtotal", "Tax", "Total", "Confirmation #"]
      orders.each do |order|
        csv << [
          order.id,
          order.submitted_at&.strftime("%Y-%m-%d"),
          order.organization&.name,
          order.location&.name,
          order.status,
          order.order_items.size,
          order.subtotal,
          order.tax,
          order.total_amount,
          order.confirmation_number
        ]
      end
    end
  end
end
