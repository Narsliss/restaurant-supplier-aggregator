class OrderListsController < ApplicationController
  before_action :require_organization!
  before_action :set_order_list, only: %i[show edit update destroy duplicate price_comparison add_match remove_match]
  before_action :require_operator!, only: %i[new create edit update destroy duplicate add_match remove_match]
  before_action :require_list_owner!, only: %i[edit update destroy duplicate add_match remove_match]
  before_action :require_location_context!

  def index
    @order_lists = scoped_order_lists
                               .includes(:order_list_items)
                               .recent

    org = current_user.current_organization
    if org
      @promoted_list = AggregatedList.for_organization(org).promoted.matched_lists.first
      @aggregated_lists = AggregatedList.for_organization(org).matched_lists
        .then { |base| @promoted_list ? base.where.not(id: @promoted_list.id) : base }
        .then { |base| chef? && current_location ? base.where(location_id: current_location.id) : base }
    end
  end

  def show
    @items = @order_list.order_list_items
                        .includes(:product_match)
                        .by_position

    # Track which product_match_ids are already in the list
    @existing_match_ids = @order_list.order_list_items.where.not(product_match_id: nil).pluck(:product_match_id).to_set

    # Load matched products from the matched list (same as new action)
    load_matched_products

    # Filter out matches already in this order list
    @available_matches = (@product_matches || []).reject { |pm| @existing_match_ids.include?(pm.id) }
  end

  def new
    @order_list = OrderList.new(
      user: current_user,
      organization: current_user.current_organization,
      location: current_location
    )
    load_matched_products
  end

  def create
    @order_list = OrderList.new(order_list_params)
    @order_list.user = current_user
    @order_list.organization = current_user.current_organization
    @order_list.location = current_location

    if @order_list.save
      # Create order list items from selected product matches
      if params[:product_match_ids].present?
        params[:product_match_ids].each_with_index do |pm_id, i|
          @order_list.order_list_items.create!(
            product_match_id: pm_id,
            quantity: 1,
            position: i + 1
          )
        end
      end
      redirect_to @order_list
    else
      load_matched_products
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @order_list.update(order_list_params)
      redirect_to @order_list
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @order_list.destroy
    redirect_to order_lists_path
  end

  def duplicate
    new_name = params[:name].presence || "#{@order_list.name} (Copy)"
    new_list = @order_list.duplicate!(new_name)
    redirect_to new_list
  rescue StandardError => e
    redirect_to @order_list
  end

  def price_comparison
    @comparison = Orders::PriceComparisonService.new(@order_list).compare
    @suppliers = Supplier.active.where(
      id: scoped_credentials.active.select(:supplier_id)
    )

    # Pre-compute split order preview for the best-price summary
    split_service = Orders::SplitOrderService.new(@order_list, location: current_location)
    @split_preview = split_service.preview

    respond_to do |format|
      format.html
      format.json { render json: @comparison }
    end
  end

  def add_match
    pm = ProductMatch.find(params[:product_match_id])
    unless @order_list.order_list_items.exists?(product_match_id: pm.id)
      @order_list.order_list_items.create!(product_match_id: pm.id, quantity: 1)
    end
    redirect_to @order_list, notice: "#{pm.canonical_name} added to list."
  end

  def remove_match
    item = @order_list.order_list_items.find_by(product_match_id: params[:product_match_id])
    item&.destroy
    redirect_to @order_list, notice: "Item removed from list."
  end

  private

  def set_order_list
    @order_list = scoped_order_lists.find(params[:id])
  end

  # Owners can edit any list; chefs/managers can only edit their own
  def require_list_owner!
    return if owner?
    return if @order_list.user_id == current_user.id

    redirect_to order_lists_path, alert: "You can only edit your own order lists."
  end

  def order_list_params
    params.require(:order_list).permit(:name, :description, :is_favorite)
  end

  def load_matched_products
    org = current_user.current_organization
    return @product_matches = [] unless org

    # Find the matched list (promoted org-wide or location-specific)
    # Allow 'failed' status too — a failed re-match job doesn't invalidate existing matches
    @matched_list = AggregatedList.for_organization(org).promoted.where(match_status: %w[matched failed]).first
    @matched_list ||= AggregatedList.for_organization(org)
                        .matched_lists.where(match_status: %w[matched failed])
                        .where(location_id: current_location&.id)
                        .first

    return @product_matches = [] unless @matched_list

    @product_matches = @matched_list.product_matches
      .where(match_status: %w[confirmed auto_matched manual])
      .includes(product_match_items: { supplier_list_item: :supplier_product })
      .order(:position)
  end
end
