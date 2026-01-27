class OrderListItemsController < ApplicationController
  before_action :set_order_list
  before_action :set_item, only: [:update, :destroy]

  def create
    @item = @order_list.order_list_items.new(item_params)

    if @item.save
      respond_to do |format|
        format.html { redirect_to @order_list, notice: "Item added." }
        format.turbo_stream
        format.json { render json: @item, status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_to @order_list, alert: @item.errors.full_messages.join(", ") }
        format.json { render json: { errors: @item.errors }, status: :unprocessable_entity }
      end
    end
  end

  def update
    if @item.update(item_params)
      respond_to do |format|
        format.html { redirect_to @order_list, notice: "Item updated." }
        format.turbo_stream
        format.json { render json: @item }
      end
    else
      respond_to do |format|
        format.html { redirect_to @order_list, alert: @item.errors.full_messages.join(", ") }
        format.json { render json: { errors: @item.errors }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    @item.destroy

    respond_to do |format|
      format.html { redirect_to @order_list, notice: "Item removed." }
      format.turbo_stream
      format.json { head :no_content }
    end
  end

  private

  def set_order_list
    @order_list = current_user.order_lists.find(params[:order_list_id])
  end

  def set_item
    @item = @order_list.order_list_items.find(params[:id])
  end

  def item_params
    params.require(:order_list_item).permit(:product_id, :quantity, :notes, :position)
  end
end
