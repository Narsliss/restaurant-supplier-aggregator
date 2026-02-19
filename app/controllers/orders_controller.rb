class OrdersController < ApplicationController
  before_action :set_order, only: [:show, :edit, :update, :destroy, :submit, :cancel]

  def index
    orders_scope = current_user.orders
      .completed
      .includes(:supplier, :location, :order_items, :order_list)
      .order(submitted_at: :desc)

    # Default date range: last 30 days
    @date_from = params[:date_from].present? ? Date.parse(params[:date_from]) : 30.days.ago.to_date
    @date_to = params[:date_to].present? ? Date.parse(params[:date_to]) : Date.current

    orders_scope = orders_scope.where("submitted_at >= ?", @date_from.beginning_of_day)
    orders_scope = orders_scope.where("submitted_at <= ?", @date_to.end_of_day)

    # Filter by supplier
    if params[:supplier_id].present?
      orders_scope = orders_scope.where(supplier_id: params[:supplier_id])
    end

    # Search by order ID or confirmation number
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      orders_scope = orders_scope.where("CAST(orders.id AS TEXT) LIKE ? OR confirmation_number LIKE ?", search_term, search_term)
    end

    # KPI: total savings across filtered orders
    @total_savings = orders_scope.sum(:savings_amount)
    @total_spent = orders_scope.sum(:total_amount)
    @order_count = orders_scope.count

    # Group orders by order_list_id for split order display
    # Orders with same order_list_id were part of one split order
    all_orders = orders_scope.to_a
    @order_groups = all_orders.group_by { |o| o.order_list_id || "standalone_#{o.id}" }
      .values
      .sort_by { |group| group.map(&:submitted_at).compact.max || Time.at(0) }
      .reverse

    @suppliers = Supplier.joins(:orders)
      .where(orders: { user_id: current_user.id, status: %w[submitted confirmed] })
      .distinct.order(:name)
  end

  def show
    @items = @order.order_items.includes(supplier_product: :supplier)
    @validations = @order.order_validations.order(validated_at: :desc)
  end

  def new
    @order_list = current_user.order_lists.find(params[:order_list_id]) if params[:order_list_id]
    @supplier = Supplier.find(params[:supplier_id]) if params[:supplier_id]

    if @order_list && @supplier
      builder = Orders::OrderBuilderService.new(
        user: current_user,
        order_list: @order_list,
        supplier: @supplier,
        location: current_location
      )
      @preview = builder.preview
      @order = builder.build
    else
      @order = current_user.orders.new
      @order_lists = current_user.order_lists.recent
      @suppliers = Supplier.active.where(
        id: current_user.supplier_credentials.active.select(:supplier_id)
      )
    end
  end

  def create
    @order_list = current_user.order_lists.find(params[:order][:order_list_id])
    @supplier = Supplier.find(params[:order][:supplier_id])
    delivery_date = params[:order][:delivery_date]

    builder = Orders::OrderBuilderService.new(
      user: current_user,
      order_list: @order_list,
      supplier: @supplier,
      location: current_location
    )

    begin
      @order = builder.build_and_save!
      @order.update!(
        delivery_date: delivery_date,
        notes: params[:order][:notes]
      )
      redirect_to @order, notice: "Order created. Review and submit when ready."
    rescue ArgumentError => e
      redirect_to new_order_path(order_list_id: @order_list.id), alert: e.message
    end
  end

  def edit
    redirect_to @order, alert: "Cannot edit submitted orders." unless @order.pending?
  end

  def update
    if @order.pending? && @order.update(order_params)
      @order.recalculate_totals!
      redirect_to @order, notice: "Order updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @order.pending?
      @order.destroy
      redirect_to orders_path, notice: "Order deleted."
    else
      redirect_to @order, alert: "Cannot delete submitted orders."
    end
  end

  def submit
    unless @order.can_submit?
      redirect_to @order, alert: "This order cannot be submitted."
      return
    end

    # Queue the order placement job
    PlaceOrderJob.perform_later(
      @order.id,
      accept_price_changes: params[:accept_price_changes] == "true",
      skip_warnings: params[:skip_warnings] == "true"
    )

    @order.update!(status: "processing")
    redirect_to @order, notice: "Order is being submitted..."
  end

  def cancel
    if @order.cancel!
      redirect_to @order, notice: "Order cancelled."
    else
      redirect_to @order, alert: "Cannot cancel this order."
    end
  end

  # Split order - preview
  def split_preview
    @order_list = current_user.order_lists.find(params[:order_list_id])
    @service = Orders::SplitOrderService.new(@order_list, location: current_location)
    @preview = @service.preview
  end

  # Split order - create all orders
  def split_create
    @order_list = current_user.order_lists.find(params[:order_list_id])
    delivery_date = params[:delivery_date]

    service = Orders::SplitOrderService.new(@order_list, location: current_location)

    begin
      @orders = service.create_orders!(delivery_date: delivery_date)

      if params[:submit_immediately] == "true"
        service.submit_all!(@orders)
        redirect_to orders_path, notice: "#{@orders.size} orders created and submitted to suppliers."
      else
        redirect_to orders_path, notice: "#{@orders.size} orders created. Review and submit when ready."
      end
    rescue Orders::SplitOrderService::OrderMinimumError => e
      redirect_to split_preview_orders_path(order_list_id: @order_list.id),
        alert: "#{e.supplier.name} minimum not met. Need $#{'%.2f' % e.minimum}, have $#{'%.2f' % e.current}."
    rescue => e
      redirect_to split_preview_orders_path(order_list_id: @order_list.id),
        alert: "Failed to create orders: #{e.message}"
    end
  end

  private

  def set_order
    @order = current_user.orders.find(params[:id])
  end

  def order_params
    params.require(:order).permit(:location_id, :notes, :delivery_date)
  end
end
