class OrderListsController < ApplicationController
  before_action :require_organization!
  before_action :set_order_list, only: %i[show edit update destroy duplicate price_comparison order_builder]
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

    # Pre-compute product IDs already in the list for O(1) lookup in the view
    # (replaces O(n×m) any? scan per search result)
    @existing_product_ids = @order_list.order_list_items.pluck(:product_id).to_set

    # Pre-compute best price per item (using already-eager-loaded supplier_products)
    # to avoid recomputing in both mobile and desktop sections of the view
    @best_prices = {}
    @items.each do |item|
      @best_prices[item.id] = item.product.supplier_products
                                   .select { |sp| sp.current_price.present? && !sp.discontinued? }
                                   .min_by(&:current_price)
    end

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

  def order_builder
    @items = @order_list.order_list_items
      .includes(product_match: { product_match_items: { supplier_list_item: [:supplier_product, { supplier_list: :supplier }] } })
      .by_position

    # Build supplier + price data from matched products
    @suppliers = []
    @price_data = {}

    @items.each do |item|
      next unless item.product_match

      item.product_match.product_match_items.each do |pmi|
        supplier = pmi.supplier_list_item&.supplier_list&.supplier
        next unless supplier
        @suppliers << supplier
        @price_data[item.id] ||= {}
        @price_data[item.id][supplier.id] = {
          price: pmi.supplier_list_item.price,
          pack_size: pmi.supplier_list_item.pack_size,
          per_unit_price: pmi.supplier_list_item.per_unit_price,
          supplier_product: pmi.supplier_list_item.supplier_product
        }
      end
    end

    @suppliers = @suppliers.uniq
  end

  private

  def set_order_list
    @order_list = scoped_order_lists.find(params[:id])
  end

  def order_list_params
    params.require(:order_list).permit(:name, :description, :is_favorite)
  end

  def load_matched_products
    org = current_user.current_organization
    return @product_matches = [] unless org

    # Find the matched list (promoted org-wide or location-specific)
    @matched_list = AggregatedList.for_organization(org).promoted.matched.first
    @matched_list ||= AggregatedList.for_organization(org)
                        .matched_lists.matched
                        .where(location_id: current_location&.id)
                        .first

    return @product_matches = [] unless @matched_list

    @product_matches = @matched_list.product_matches
      .where(match_status: %w[confirmed auto_matched manual])
      .includes(product_match_items: { supplier_list_item: :supplier_product })
      .order(:position)
  end
end
