class OrderItemsController < ApplicationController
  before_action :set_order_item

  # PATCH /order-history/:order_id/order_items/:id
  # Updates quantity on a single item, recalculates order totals.
  # Returns JSON with updated item + order totals + minimum status.
  def update
    unless @order.pending?
      render json: { error: "Cannot edit non-pending orders" }, status: :unprocessable_entity
      return
    end

    new_qty = params[:quantity].to_i
    if new_qty <= 0
      render json: { error: "Quantity must be greater than 0" }, status: :unprocessable_entity
      return
    end

    @order_item.update!(
      quantity: new_qty,
      line_total: @order_item.unit_price * new_qty
    )
    @order.recalculate_totals!
    @order.update!(savings_amount: @order.calculate_savings)

    render json: order_item_json
  end

  # DELETE /order-history/:order_id/order_items/:id
  # Removes an item. If order has no items left, destroys the empty order.
  def destroy
    unless @order.pending?
      render json: { error: "Cannot edit non-pending orders" }, status: :unprocessable_entity
      return
    end

    @order_item.destroy!

    if @order.order_items.reload.empty?
      order_id = @order.id
      @order.destroy!
      render json: { removed: true, order_removed: true, order_id: order_id }
    else
      @order.recalculate_totals!
      @order.update!(savings_amount: @order.calculate_savings)
      render json: { removed: true, order_removed: false, order: order_json }
    end
  end

  private

  def set_order_item
    @order = current_user.orders.find(params[:order_id])
    @order_item = @order.order_items.find(params[:id])
  end

  def order_item_json
    minimum = @order.supplier.order_minimum
    {
      item: {
        id: @order_item.id,
        quantity: @order_item.quantity,
        unit_price: @order_item.unit_price,
        line_total: @order_item.line_total
      },
      order: order_json,
      minimum: minimum,
      meets_minimum: minimum.nil? || @order.subtotal >= minimum
    }
  end

  def order_json
    {
      id: @order.id,
      subtotal: @order.subtotal,
      total_amount: @order.total_amount,
      item_count: @order.order_items.count,
      savings_amount: @order.savings_amount
    }
  end
end
