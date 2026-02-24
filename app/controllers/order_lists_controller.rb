class OrderListsController < ApplicationController
  before_action :require_organization!
  before_action :set_order_list, only: %i[show edit update destroy duplicate price_comparison]
  before_action :require_operator!, only: %i[new create edit update destroy duplicate]
  before_action :require_location_context!

  def index
    @order_lists = scoped_order_lists
                               .includes(:order_list_items)
                               .recent
  end

  def show
    @items = @order_list.order_list_items
                        .includes(product: { supplier_products: :supplier })
                        .by_position

    # Get categories for filter dropdown
    @categories = AiProductCategorizer::CATEGORIES
    @subcategories = params[:category].present? ? @categories.dig(params[:category], :subcategories) || [] : []

    # Search products to add (when search/filter is active)
    return unless params[:search].present? || params[:category].present? || params[:subcategory].present?

    @search_results = Product.includes(supplier_products: :supplier)

    @search_results = @search_results.search(params[:search]) if params[:search].present?

    @search_results = @search_results.where(category: params[:category]) if params[:category].present?

    @search_results = @search_results.where(subcategory: params[:subcategory]) if params[:subcategory].present?

    @search_results = @search_results.order(:name).page(1).per(50)
  end

  def new
    @order_list = OrderList.new(
      user: current_user,
      organization: current_user.current_organization,
      location: current_location
    )
  end

  def create
    @order_list = OrderList.new(order_list_params)
    @order_list.user = current_user
    @order_list.organization = current_user.current_organization
    @order_list.location = current_location

    if @order_list.save
      redirect_to @order_list
    else
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

  private

  def set_order_list
    @order_list = scoped_order_lists.find(params[:id])
  end

  def order_list_params
    params.require(:order_list).permit(:name, :description, :is_favorite)
  end
end
