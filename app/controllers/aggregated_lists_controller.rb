class AggregatedListsController < ApplicationController
  before_action :set_aggregated_list, only: %i[show edit update destroy run_matching order_builder]

  def show
    @supplier_lists = @aggregated_list.supplier_lists.includes(:supplier)
    @product_matches = @aggregated_list.product_matches
                                       .includes(product_match_items: %i[supplier supplier_list_item])
                                       .order(Arel.sql("CASE match_status WHEN 'confirmed' THEN 0 WHEN 'manual' THEN 1 WHEN 'auto_matched' THEN 2 WHEN 'unmatched' THEN 3 WHEN 'rejected' THEN 4 ELSE 5 END, position ASC"))
    @suppliers = @supplier_lists.map(&:supplier).uniq

    # Load all items per supplier for dropdown reassignment
    @items_by_supplier = {}
    @supplier_lists.each do |sl|
      @items_by_supplier[sl.supplier_id] = sl.supplier_list_items
                                             .select(:id, :name, :sku, :price, :pack_size)
                                             .order(:name)
    end
  end

  def new
    @aggregated_list = AggregatedList.new
    @available_lists = available_supplier_lists
  end

  def create
    @aggregated_list = AggregatedList.new(aggregated_list_params)
    @aggregated_list.organization = current_user.current_organization
    @aggregated_list.created_by = current_user

    if @aggregated_list.save
      # Connect selected supplier lists
      update_list_mappings

      # Trigger AI matching in background
      AiProductMatchJob.perform_later(@aggregated_list.id) if @aggregated_list.supplier_lists.count >= 2

      if params[:return_to] == "supplier_lists"
        redirect_to supplier_lists_path, notice: "#{@aggregated_list.name} created. Matching products..."
      else
        redirect_to @aggregated_list, notice: "#{@aggregated_list.name} created. Matching products..."
      end
    else
      if params[:return_to] == "supplier_lists"
        redirect_to supplier_lists_path, alert: @aggregated_list.errors.full_messages.join(", ")
      else
        @available_lists = available_supplier_lists
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit
    @available_lists = available_supplier_lists
    @selected_list_ids = @aggregated_list.supplier_list_ids
  end

  def update
    if @aggregated_list.update(aggregated_list_params)
      update_list_mappings
      # Re-run matching if lists changed
      AiProductMatchJob.perform_later(@aggregated_list.id) if @aggregated_list.supplier_lists.count >= 2

      redirect_to @aggregated_list, notice: "#{@aggregated_list.name} updated. Re-matching products..."
    else
      @available_lists = available_supplier_lists
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @aggregated_list.name
    @aggregated_list.destroy
    redirect_to supplier_lists_path, notice: "#{name} deleted."
  end

  def run_matching
    @aggregated_list.update(match_status: 'matching')
    AiProductMatchJob.perform_later(@aggregated_list.id)
    redirect_to @aggregated_list, notice: 'Re-running product matching...'
  end

  def order_builder
    unless @aggregated_list.matched?
      redirect_to @aggregated_list, alert: "Product matching must be complete before creating an order."
      return
    end

    @product_matches = @aggregated_list.product_matches
                                       .where.not(match_status: 'rejected')
                                       .includes(product_match_items: [:supplier, { supplier_list_item: :supplier_product }])
                                       .order(Arel.sql("CASE match_status WHEN 'confirmed' THEN 0 WHEN 'manual' THEN 1 WHEN 'auto_matched' THEN 2 WHEN 'unmatched' THEN 3 ELSE 4 END, position ASC"))
    @suppliers = @aggregated_list.suppliers

    # Pre-fill quantities from existing pending batch orders (when returning from review page)
    @quantities = {}
    @delivery_date = nil
    if params[:batch_id].present?
      batch_orders = current_user.orders.for_batch(params[:batch_id]).pending
                       .includes(order_items: :supplier_product)
      if batch_orders.any?
        @delivery_date = batch_orders.first.delivery_date

        # Build lookup: supplier_product_id → product_match_id
        sp_to_match = {}
        @product_matches.each do |pm|
          pm.product_match_items.each do |pmi|
            sp = pmi.supplier_list_item&.supplier_product
            sp_to_match[sp.id] = pm.id if sp
          end
        end

        # Map order items back to product matches
        batch_orders.each do |order|
          order.order_items.each do |oi|
            match_id = sp_to_match[oi.supplier_product_id]
            @quantities[match_id.to_s] = oi.quantity if match_id
          end
        end

        # Delete the pending batch orders since user is re-editing
        batch_orders.destroy_all
      end
    end

    # --- Category grouping ---
    # Bulk-fetch categories via SupplierProduct → Product (single query, no N+1)
    sp_ids = @product_matches.flat_map { |pm|
      pm.product_match_items.filter_map { |pmi| pmi.supplier_list_item.supplier_product_id }
    }
    categories_by_sp_id = Product.joins(:supplier_products)
                                 .where(supplier_products: { id: sp_ids })
                                 .where.not(category: [nil, ""])
                                 .pluck("supplier_products.id", "products.category")
                                 .to_h

    @match_category = {}
    @product_matches.each do |pm|
      raw = pm.product_match_items.filter_map { |pmi|
        categories_by_sp_id[pmi.supplier_list_item.supplier_product_id]
      }.first
      @match_category[pm.id] = ::CategoryNormalizable.normalize(raw)
    end

    # --- Frequently ordered & user favorites (stars) ---
    frequency_counts = OrderItem.joins(:order)
                                .where(orders: { organization_id: @aggregated_list.organization_id,
                                                 status: %w[submitted confirmed] })
                                .group(:supplier_product_id)
                                .count

    # User's manually-favorited supplier_product IDs (single query)
    favorited_sp_ids = current_user.favorite_products.pluck(:supplier_product_id).to_set

    @frequently_ordered = {}  # match_id → true if starred (frequency OR manual fav)
    @user_favorited     = {}  # match_id → true if user manually favorited
    @match_sp_ids       = {}  # match_id → first supplier_product_id (for toggle endpoint)

    @product_matches.each do |pm|
      first_sp_id = nil
      freq = false
      fav  = false

      pm.product_match_items.each do |pmi|
        sp_id = pmi.supplier_list_item.supplier_product_id
        next unless sp_id
        first_sp_id ||= sp_id
        freq = true if (frequency_counts[sp_id] || 0) >= 3
        fav  = true if favorited_sp_ids.include?(sp_id)
      end

      @frequently_ordered[pm.id] = freq || fav
      @user_favorited[pm.id]     = fav
      @match_sp_ids[pm.id]       = first_sp_id
    end

    # Split frequently ordered / favorited into their own section
    frequent_matches = @product_matches.select { |pm| @frequently_ordered[pm.id] }
    remaining_matches = @product_matches.reject { |pm| @frequently_ordered[pm.id] }

    @grouped_matches = remaining_matches.group_by { |pm| @match_category[pm.id] || "Other" }
    @sorted_categories = @grouped_matches.keys.sort_by { |c| c == "Other" ? "zzz" : c.downcase }

    # Prepend "Frequently Ordered" section if any exist
    if frequent_matches.any?
      @grouped_matches = { "Frequently Ordered" => frequent_matches }.merge(@grouped_matches)
      @sorted_categories.unshift("Frequently Ordered")
    end
  end

  private

  def set_aggregated_list
    @aggregated_list = current_organization_aggregated_lists.find(params[:id])
  end

  def current_organization_aggregated_lists
    if current_user.current_organization
      AggregatedList.for_organization(current_user.current_organization)
    else
      current_user.created_aggregated_lists
    end
  end

  def available_supplier_lists
    if current_user.current_organization
      SupplierList.for_organization(current_user.current_organization)
                  .includes(:supplier)
                  .order('suppliers.name ASC, supplier_lists.name ASC')
    else
      SupplierList.joins(:supplier_credential)
                  .where(supplier_credentials: { user_id: current_user.id })
                  .includes(:supplier)
    end
  end

  def aggregated_list_params
    params.require(:aggregated_list).permit(:name, :description)
  end

  def update_list_mappings
    return unless params[:supplier_list_ids]

    new_ids = params[:supplier_list_ids].reject(&:blank?).map(&:to_i)
    current_ids = @aggregated_list.supplier_list_ids

    # Remove deselected
    (current_ids - new_ids).each do |id|
      @aggregated_list.aggregated_list_mappings.find_by(supplier_list_id: id)&.destroy
    end

    # Add new
    (new_ids - current_ids).each do |id|
      @aggregated_list.aggregated_list_mappings.create(supplier_list_id: id)
    end
  end
end
