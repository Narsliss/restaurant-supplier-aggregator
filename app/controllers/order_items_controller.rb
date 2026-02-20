class OrderItemsController < ApplicationController
  before_action :set_order
  before_action :set_order_item, only: [:update, :destroy]

  # POST /order-history/:order_id/order_items
  # Adds a product to a pending order (e.g., from suggestion quick-add).
  # Expects JSON: { supplier_product_id: Integer, quantity: Integer }
  def create
    unless @order.pending? || @order.price_changed?
      render json: { error: "Cannot add items to this order" }, status: :unprocessable_entity
      return
    end

    supplier_product = SupplierProduct
      .where(supplier_id: @order.supplier_id)
      .available
      .in_stock
      .find(params[:supplier_product_id])

    qty = [params[:quantity].to_i, 1].max
    is_existing = false

    # If product already in the order, increment quantity
    existing = @order.order_items.find_by(supplier_product: supplier_product)
    if existing
      new_qty = existing.quantity + qty
      existing.update!(quantity: new_qty, line_total: existing.unit_price * new_qty)
      @order_item = existing
      is_existing = true
    else
      @order_item = @order.order_items.create!(
        supplier_product: supplier_product,
        quantity: qty,
        unit_price: supplier_product.current_price,
        line_total: supplier_product.current_price * qty,
        status: "pending"
      )
    end

    @order.recalculate_totals!
    @order.update!(savings_amount: @order.calculate_savings)

    minimum = @order.supplier.order_minimum
    render json: {
      item: {
        id: @order_item.id,
        supplier_product_id: @order_item.supplier_product_id,
        name: @order_item.supplier_product.supplier_name,
        sku: @order_item.supplier_product.supplier_sku,
        pack_size: @order_item.supplier_product.pack_size,
        quantity: @order_item.quantity,
        unit_price: @order_item.unit_price,
        line_total: @order_item.line_total
      },
      order: order_json,
      minimum: minimum,
      meets_minimum: minimum.nil? || @order.subtotal >= minimum,
      is_existing: is_existing
    }
  end

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

  def set_order
    @order = current_user.orders.find(params[:order_id])
  end

  def set_order_item
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
