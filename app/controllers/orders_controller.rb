class OrdersController < ApplicationController
  before_action :set_order, only: [:show, :edit, :update, :destroy, :submit, :cancel]

  def index
    @orders = current_user.orders
      .includes(:supplier, :location, :order_items)
      .order(created_at: :desc)
      .page(params[:page])
  end

  def history
    @orders = current_user.orders
      .completed
      .includes(:supplier, :location)
      .order(submitted_at: :desc)
      .page(params[:page])
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

    builder = Orders::OrderBuilderService.new(
      user: current_user,
      order_list: @order_list,
      supplier: @supplier,
      location: current_location
    )

    begin
      @order = builder.build_and_save!
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

  private

  def set_order
    @order = current_user.orders.find(params[:id])
  end

  def order_params
    params.require(:order).permit(:location_id, :notes)
  end
end
