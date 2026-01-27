class PriceComparisonsController < ApplicationController
  before_action :set_order_list

  def show
    @comparison = Orders::PriceComparisonService.new(@order_list).compare

    respond_to do |format|
      format.html
      format.json { render json: @comparison }
    end
  end

  def refresh_prices
    service = Orders::PriceComparisonService.new(@order_list)
    service.refresh_prices!

    respond_to do |format|
      format.html { redirect_to price_comparison_path(@order_list), notice: "Price refresh started..." }
      format.json { render json: { status: "refreshing" } }
    end
  end

  private

  def set_order_list
    @order_list = current_user.order_lists.find(params[:id])
  end
end
