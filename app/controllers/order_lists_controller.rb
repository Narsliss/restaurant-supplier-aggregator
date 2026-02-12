class OrderListsController < ApplicationController
  before_action :set_order_list, only: [:show, :edit, :update, :destroy, :duplicate, :price_comparison]

  def index
    @order_lists = current_user.order_lists
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
    if params[:search].present? || params[:category].present? || params[:subcategory].present?
      @search_results = Product.includes(supplier_products: :supplier)

      if params[:search].present?
        @search_results = @search_results.where("name LIKE ?", "%#{params[:search]}%")
      end

      if params[:category].present?
        @search_results = @search_results.where(category: params[:category])
      end

      if params[:subcategory].present?
        @search_results = @search_results.where(subcategory: params[:subcategory])
      end

      @search_results = @search_results.order(:name).page(1).per(50)
    end
  end

  def new
    @order_list = current_user.order_lists.new
  end

  def create
    @order_list = current_user.order_lists.new(order_list_params)

    if @order_list.save
      redirect_to @order_list, notice: "Order list created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @order_list.update(order_list_params)
      redirect_to @order_list, notice: "Order list updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @order_list.destroy
    redirect_to order_lists_path, notice: "Order list deleted."
  end

  def duplicate
    new_name = params[:name].presence || "#{@order_list.name} (Copy)"
    new_list = @order_list.duplicate!(new_name)
    redirect_to new_list, notice: "Order list duplicated."
  rescue => e
    redirect_to @order_list, alert: "Failed to duplicate: #{e.message}"
  end

  def price_comparison
    @comparison = Orders::PriceComparisonService.new(@order_list).compare
    @suppliers = Supplier.active.where(
      id: current_user.supplier_credentials.active.select(:supplier_id)
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
    @order_list = current_user.order_lists.find(params[:id])
  end

  def order_list_params
    params.require(:order_list).permit(:name, :description, :is_favorite)
  end
end
