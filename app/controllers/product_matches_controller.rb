class ProductMatchesController < ApplicationController
  before_action :require_location_context!
  before_action :set_aggregated_list
  before_action :set_product_match, only: %i[confirm reject rename]
  before_action :require_list_write_access!, only: %i[confirm reject rename confirm_all]

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
      format.json { render json: { status: "rejected" } }
      format.html { redirect_to aggregated_list_product_matches_path(@aggregated_list) }
      format.turbo_stream
    end
  end

  def rename
    name = params[:canonical_name].to_s.strip.presence
    @product_match.update!(canonical_name: name&.truncate(255))

    respond_to do |format|
      format.json { render json: { name: @product_match.display_name } }
      format.html { redirect_to aggregated_list_path(@aggregated_list) }
    end
  end

  def confirm_all
    count = @aggregated_list.product_matches.auto_matched.high_confidence.update_all(match_status: 'confirmed')
    redirect_to aggregated_list_product_matches_path(@aggregated_list),
                notice: "Confirmed #{count} high-confidence matches."
  end

  private

  def set_aggregated_list
    @aggregated_list = current_organization_aggregated_lists.find(params[:aggregated_list_id])
  end

  def set_product_match
    @product_match = @aggregated_list.product_matches.find(params[:id])
  end

  def current_organization_aggregated_lists
    if current_user.current_organization
      base = AggregatedList.for_organization(current_user.current_organization)
      if chef? && current_location
        base = base.where(location_id: current_location.id).or(base.where(promoted_org_wide: true))
      end
      base
    else
      AggregatedList.none
    end
  end

  # Chefs can only modify lists at their own location
  def require_list_write_access!
    return if current_user.super_admin? || owner?
    return unless @aggregated_list

    if @aggregated_list.location_id != current_location&.id
      redirect_to root_path, alert: "You don't have permission to modify this list."
    end
  end
end
