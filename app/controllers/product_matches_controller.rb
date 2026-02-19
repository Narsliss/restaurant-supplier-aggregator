class ProductMatchesController < ApplicationController
  before_action :set_aggregated_list
  before_action :set_product_match, only: %i[confirm reject]

  def index
    @product_matches = @aggregated_list.product_matches
                                       .includes(product_match_items: %i[supplier supplier_list_item])
                                       .by_position
    @suppliers = @aggregated_list.supplier_lists.includes(:supplier).map(&:supplier).uniq
  end

  def confirm
    @product_match.confirm!

    respond_to do |format|
      format.html { redirect_to aggregated_list_product_matches_path(@aggregated_list) }
      format.turbo_stream
    end
  end

  def reject
    @product_match.reject!

    respond_to do |format|
      format.html { redirect_to aggregated_list_product_matches_path(@aggregated_list) }
      format.turbo_stream
    end
  end

  def confirm_all
    count = @aggregated_list.product_matches.auto_matched.high_confidence.update_all(match_status: 'confirmed')
    redirect_to aggregated_list_product_matches_path(@aggregated_list),
                notice: "Confirmed #{count} high-confidence matches."
  end

  private

  def set_aggregated_list
    @aggregated_list = AggregatedList.find(params[:aggregated_list_id])
  end

  def set_product_match
    @product_match = @aggregated_list.product_matches.find(params[:id])
  end
end
