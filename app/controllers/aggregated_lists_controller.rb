class AggregatedListsController < ApplicationController
  before_action :require_location_context!
  before_action :set_aggregated_list, only: %i[show edit update destroy run_matching sync_new_products search_catalog order_builder add_supplier_guide promote demote supplier_items_search]
  before_action :require_owner!, only: %i[promote demote]
  before_action :require_not_promoted!, only: %i[edit update destroy run_matching sync_new_products add_supplier_guide]
  before_action :require_list_location_access!, only: %i[edit update destroy run_matching sync_new_products add_supplier_guide]

  def index
    @aggregated_lists = current_organization_aggregated_lists
                          .includes(supplier_lists: :supplier)
                          .order(updated_at: :desc)
    @matched_lists = @aggregated_lists.matched_lists
    @custom_lists = @aggregated_lists.custom_lists
    @location_has_matched_list = current_location && @matched_lists.where(location_id: current_location.id).exists?

    # Promoted org-wide list takes precedence — chefs see it as the primary list
    @promoted_list = @matched_lists.find(&:promoted?)
    if @promoted_list
      @location_lists = @matched_lists.reject(&:promoted?)
    end

    # Chefs only see their own location's list (not all org lists)
    if chef? && current_location && !@promoted_list
      @matched_lists = @matched_lists.where(location_id: current_location.id)
    end
  end

  def show
    # Auto-add any supplier lists at this location that aren't yet linked (safety net)
    if @aggregated_list.matched_list? && @aggregated_list.location_id
      existing_ids = @aggregated_list.supplier_list_ids
      missing = SupplierList.where(location_id: @aggregated_list.location_id, organization_id: @aggregated_list.organization_id)
                            .where.not(id: existing_ids)
      missing.find_each do |sl|
        @aggregated_list.aggregated_list_mappings.create!(supplier_list_id: sl.id)
        Rails.logger.info "[AutoAdd] Show safety-net: added supplier list #{sl.id} (#{sl.name}) to matched list #{@aggregated_list.id}"
      end
      @aggregated_list.reload if missing.any?
    end

    @supplier_lists = @aggregated_list.supplier_lists.includes(:supplier)
    @product_matches = @aggregated_list.product_matches
                                       .includes(product_match_items: [:supplier, { supplier_list_item: :supplier_product }])
                                       .order(Arel.sql("CASE match_status WHEN 'confirmed' THEN 0 WHEN 'manual' THEN 1 WHEN 'auto_matched' THEN 2 WHEN 'unmatched' THEN 3 WHEN 'rejected' THEN 4 ELSE 5 END, position ASC"))
    @suppliers = @supplier_lists.map(&:supplier).uniq

    # Pre-compute stats with a single grouped query instead of 3 separate COUNTs
    status_counts = @aggregated_list.product_matches.group(:match_status).count
    @stats = {
      total: status_counts.values.sum,
      matched: (status_counts['confirmed'] || 0) + (status_counts['auto_matched'] || 0) + (status_counts['manual'] || 0),
      unmatched: status_counts['unmatched'] || 0
    }

    # Pre-build lookup: match_id -> { supplier_id -> { pmi:, item: } }
    # Eliminates N+1 find_by queries in the view (was ~1600 queries for 200 matches × 4 suppliers)
    @match_supplier_map = {}
    @price_data = {}

    @product_matches.each do |match|
      supplier_map = {}
      match.product_match_items.each do |pmi|
        supplier_map[pmi.supplier_id] = { pmi: pmi, item: pmi.supplier_list_item }
      end
      @match_supplier_map[match.id] = supplier_map

      # Pre-compute price comparison per match (cheapest/most_expensive/spread)
      # Avoids calling prices_by_supplier 3× per row in the view
      prices = match.product_match_items.map do |pmi|
        item = pmi.supplier_list_item
        sp = item.supplier_product
        {
          supplier: pmi.supplier,
          price: item.price || sp&.current_price,
          per_unit_price: item.per_unit_price,
          normalized_unit: item.normalized_unit,
          in_stock: sp ? sp.in_stock : item.read_attribute(:in_stock)
        }
      end

      in_stock_prices = prices.select { |p| p[:price].present? && p[:in_stock] }

      # Prefer per-unit comparison: find items with per-unit prices and matching units
      with_per_unit = in_stock_prices.select { |p| p[:per_unit_price].present? && p[:normalized_unit].present? }
      unit_groups = with_per_unit.group_by { |p| p[:normalized_unit] }
      largest_group = unit_groups.max_by { |_unit, items| items.size }&.last || []

      cheapest = most_expensive = nil
      if largest_group.size >= 2
        # Compare by per-unit price when at least 2 items share the same unit
        cheapest = largest_group.min_by { |p| p[:per_unit_price] }
        most_expensive = largest_group.max_by { |p| p[:per_unit_price] }
      elsif in_stock_prices.any?
        # Fallback to case price when per-unit comparison isn't possible
        cheapest = in_stock_prices.min_by { |p| p[:price] }
        most_expensive = in_stock_prices.max_by { |p| p[:price] }
      end

      with_price = prices.select { |p| p[:price].present? }
      spread = nil
      if with_price.size >= 2
        per_unit_with_price = with_price.select { |p| p[:per_unit_price].present? && p[:normalized_unit].present? }
        price_unit_groups = per_unit_with_price.group_by { |p| p[:normalized_unit] }
        largest_price_group = price_unit_groups.max_by { |_unit, items| items.size }&.last || []

        if largest_price_group.size >= 2
          spread = largest_price_group.map { |p| p[:per_unit_price] }.max - largest_price_group.map { |p| p[:per_unit_price] }.min
        else
          spread = with_price.map { |p| p[:price] }.max - with_price.map { |p| p[:price] }.min
        end
      end

      @price_data[match.id] = {
        cheapest_supplier: cheapest&.dig(:supplier),
        most_expensive_supplier: most_expensive&.dig(:supplier),
        spread: spread
      }
    end

    # Teaser columns: show catalog data from suppliers not mapped to this list
    connected_ids = @suppliers.map(&:id)
    @unconnected_suppliers = Supplier.where(active: true).where.not(id: connected_ids).order(:name)

    if @unconnected_suppliers.any?
      # Collect canonical product_id for each match (first found wins)
      match_product_ids = {}
      @product_matches.each do |match|
        match.product_match_items.each do |pmi|
          pid = pmi.supplier_list_item.supplier_product&.product_id
          next unless pid
          match_product_ids[match.id] ||= pid
        end
      end

      # Batch query: catalog items from unconnected suppliers matching these products
      unconnected_ids = @unconnected_suppliers.map(&:id)
      teaser_by_product_and_supplier = {}

      if match_product_ids.values.any?
        SupplierProduct
          .where(supplier_id: unconnected_ids, product_id: match_product_ids.values.uniq, discontinued: false)
          .select(:id, :supplier_id, :product_id, :supplier_name, :pack_size, :current_price, :price_unit, :in_stock)
          .each do |sp|
            teaser_by_product_and_supplier[sp.product_id] ||= {}
            teaser_by_product_and_supplier[sp.product_id][sp.supplier_id] ||= sp
          end
      end

      # Build lookup: match_id -> { supplier_id -> SupplierProduct }
      @teaser_map = {}
      match_product_ids.each do |match_id, product_id|
        @teaser_map[match_id] = teaser_by_product_and_supplier[product_id] || {}
      end

      # Only show columns for suppliers that have at least one matching product
      @unconnected_suppliers = @unconnected_suppliers.select do |supplier|
        @teaser_map.values.any? { |supplier_map| supplier_map.key?(supplier.id) }
      end
    end

    @teaser_map ||= {}

    # Available guides for "Add Supplier Guide" section (matched lists only)
    if @aggregated_list.matched_list? && @aggregated_list.matched?
      @available_guides = available_supplier_lists.where.not(id: @aggregated_list.supplier_list_ids)
    end
  end

  def new
    # Redirect to existing matched list if one already exists for this location
    if params[:list_type] == 'matched' && current_location
      existing = AggregatedList.matched_lists
                               .where(organization: current_user.current_organization, location_id: current_location.id)
                               .first
      if existing
        redirect_to existing, notice: "This location already has a matched list."
        return
      end
    end

    @aggregated_list = AggregatedList.new
    @available_lists = available_supplier_lists
  end

  def create
    @aggregated_list = AggregatedList.new(aggregated_list_params)
    @aggregated_list.organization = current_user.current_organization
    @aggregated_list.created_by = current_user
    @aggregated_list.list_type = params[:list_type] if params[:list_type].present?

    if @aggregated_list.matched_list?
      @aggregated_list.location_id = current_location&.id
      @aggregated_list.name = "#{current_location.name} Matched List"

      # Each location can only have one matched list — redirect to existing if found
      existing = AggregatedList.matched_lists
                               .where(organization: @aggregated_list.organization, location_id: @aggregated_list.location_id)
                               .first
      if existing
        redirect_to existing, notice: "This location already has a matched list."
        return
      end
    end

    if @aggregated_list.save
      # Connect selected supplier lists
      update_list_mappings

      # Trigger AI matching in background
      if @aggregated_list.supplier_lists.count >= 2
        @aggregated_list.update(match_status: 'matching')
        AiProductMatchJob.perform_later(@aggregated_list.id)
      end

      if params[:return_to] == "supplier_lists"
        redirect_to supplier_lists_path
      else
        redirect_to @aggregated_list
      end
    else
      if params[:return_to] == "supplier_lists"
        redirect_to supplier_lists_path
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

      redirect_to @aggregated_list
    else
      @available_lists = available_supplier_lists
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @aggregated_list.name
    @aggregated_list.destroy
    redirect_to aggregated_lists_path, notice: "\"#{name}\" has been deleted."
  end

  def run_matching
    unless @aggregated_list.matching?
      @aggregated_list.update(match_status: 'matching')
      AiProductMatchJob.perform_later(@aggregated_list.id)
    end
    redirect_to @aggregated_list
  end

  def sync_new_products
    new_count = @aggregated_list.unmatched_supplier_items_count
    if new_count == 0
      redirect_to @aggregated_list, notice: "All products are already matched. Nothing new to sync."
      return
    end

    @aggregated_list.mark_matching!
    SyncNewProductsJob.perform_later(@aggregated_list.id)
    redirect_to @aggregated_list, notice: "Syncing #{new_count} new product(s)..."
  end

  def add_supplier_guide
    new_list_ids = params[:supplier_list_ids]&.reject(&:blank?)&.map(&:to_i) || []
    current_ids = @aggregated_list.supplier_list_ids

    # Only add new ones — never remove existing in incremental mode
    added_ids = new_list_ids - current_ids

    if added_ids.empty?
      redirect_to @aggregated_list, notice: "No new supplier guides selected."
      return
    end

    # Create mappings for new lists only
    added_ids.each do |id|
      @aggregated_list.aggregated_list_mappings.create(supplier_list_id: id)
    end

    # Trigger incremental matching (preserves all existing matches)
    @aggregated_list.mark_matching!
    IncrementalProductMatchJob.perform_later(@aggregated_list.id, added_ids)

    redirect_to @aggregated_list, notice: "Adding #{added_ids.size} supplier guide(s) and matching new products..."
  end

  def promote
    if @aggregated_list.update(promoted_org_wide: true)
      redirect_to aggregated_lists_path, notice: "\"#{@aggregated_list.name}\" is now the organization-wide list."
    else
      redirect_to aggregated_lists_path, alert: @aggregated_list.errors.full_messages.to_sentence
    end
  end

  def demote
    @aggregated_list.update!(promoted_org_wide: false)
    redirect_to aggregated_lists_path, notice: "\"#{@aggregated_list.name}\" is no longer the organization-wide list."
  end

  def supplier_items_search
    supplier_id = params[:supplier_id]
    query = params[:q].to_s.downcase.strip

    # 1. Order guide items (already on the user's lists) — these have SupplierListItem IDs
    supplier_list_ids = @aggregated_list.supplier_lists
                                        .where(supplier_id: supplier_id)
                                        .pluck(:id)
    guide_items = SupplierListItem.where(supplier_list_id: supplier_list_ids)
    guide_items = guide_items.where("LOWER(name) LIKE ?", "%#{query}%") if query.present?
    guide_results = guide_items.select(:id, :name, :price, :pack_size, :supplier_product_id)
                               .order(:name).limit(15)

    # Track which catalog products are already covered by order guide items
    covered_product_ids = guide_results.filter_map(&:supplier_product_id).to_set

    # 2. Full catalog items (not on any order guide) — these use supplier_product: prefix
    remaining = 15 - guide_results.size
    catalog_results = []
    if remaining > 0
      catalog = SupplierProduct.where(supplier_id: supplier_id, discontinued: false)
      catalog = catalog.where("LOWER(supplier_name) LIKE ?", "%#{query}%") if query.present?
      catalog = catalog.where.not(id: covered_product_ids.to_a) if covered_product_ids.any?
      catalog_results = catalog.select(:id, :supplier_name, :current_price, :pack_size)
                               .order(:supplier_name).limit(remaining)
    end

    json = guide_results.map { |i|
      { id: i.id, name: i.name.truncate(60), price: i.price ? "$#{'%.2f' % i.price}" : "N/A", pack_size: i.pack_size, source: "guide" }
    }
    json += catalog_results.map { |sp|
      { id: "sp_#{sp.id}", name: sp.supplier_name.truncate(60), price: sp.current_price ? "$#{'%.2f' % sp.current_price}" : "N/A", pack_size: sp.pack_size, source: "catalog" }
    }

    render json: json
  end

  def search_catalog
    unless @aggregated_list.matched?
      redirect_to @aggregated_list
      return
    end

    @aggregated_list.mark_searching_catalog!
    CatalogSearchJob.perform_later(@aggregated_list.id)
    redirect_to @aggregated_list
  end

  def order_builder
    # Allow matched and failed — failed means a matching job errored,
    # but existing matches are still valid and usable for ordering
    unless @aggregated_list.matched? || @aggregated_list.match_status == 'failed'
      redirect_to @aggregated_list
      return
    end

    @product_matches = @aggregated_list.product_matches
                                       .where.not(match_status: 'rejected')
                                       .includes(product_match_items: [:supplier, { supplier_list_item: :supplier_product }])
                                       .order(Arel.sql("CASE match_status WHEN 'confirmed' THEN 0 WHEN 'manual' THEN 1 WHEN 'auto_matched' THEN 2 WHEN 'unmatched' THEN 3 ELSE 4 END, position ASC"))
    # Only show suppliers the user has active credentials for at this location
    available_supplier_ids = scoped_credentials.active.pluck(:supplier_id).to_set
    @suppliers = @aggregated_list.suppliers.select { |s| available_supplier_ids.include?(s.id) }

    # --- Optional order list context (unified builder) ---
    @order_list = nil
    @order_list_match_ids = Set.new
    if params[:order_list_id].present?
      @order_list = scoped_order_lists.find_by(id: params[:order_list_id])
      if @order_list
        @order_list_match_ids = @order_list.order_list_items
          .where.not(product_match_id: nil)
          .pluck(:product_match_id)
          .to_set
      end
    end

    # --- Per-supplier minimums for command bar progress indicators (single query) ---
    supplier_ids = @suppliers.map(&:id)
    minimums_by_supplier = SupplierRequirement
      .where(supplier_id: supplier_ids, requirement_type: 'order_minimum', active: true)
      .index_by(&:supplier_id)

    @supplier_minimums = {}
    @suppliers.each do |supplier|
      req = minimums_by_supplier[supplier.id]
      @supplier_minimums[supplier.id] = {
        name: supplier.name,
        minimum: req&.numeric_value&.to_f,
        is_blocking: req&.is_blocking || false
      }
    end

    # Pre-fill quantities from existing pending batch orders (when returning from review page)
    @quantities = {}
    @delivery_date = nil
    if params[:batch_id].present?
      batch_orders = scoped_orders.for_batch(params[:batch_id]).pending
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
      normalized = ::CategoryNormalizable.normalize(raw)

      # Fallback: if no category from DB chain, use rule-based categorizer on product name
      if normalized.blank?
        name = pm.canonical_name.presence || pm.product_match_items.first&.supplier_list_item&.name
        if name.present?
          result = AiProductCategorizer.rule_based_categorize(name)
          normalized = result[:category] if result[:confidence] >= 0.7
        end
      end

      @match_category[pm.id] = normalized
    end

    # --- Frequently ordered & user favorites (stars) ---
    # Time-bounded to last 6 months — older orders aren't relevant for "frequently ordered"
    # and unbounded queries slow down as order history grows.
    frequency_counts = OrderItem.joins(:order)
                                .where(orders: { organization_id: @aggregated_list.organization_id,
                                                 status: %w[submitted confirmed] })
                                .where("orders.created_at >= ?", 6.months.ago)
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

    # --- Build grouped sections ---
    # When an order list is present, its items become the first section
    if @order_list && @order_list_match_ids.any?
      order_list_matches = @product_matches.select { |pm| @order_list_match_ids.include?(pm.id) }
      remaining_all = @product_matches.reject { |pm| @order_list_match_ids.include?(pm.id) }
    else
      order_list_matches = []
      remaining_all = @product_matches.to_a
    end

    # Split frequently ordered / favorited from the remaining matches
    frequent_matches = remaining_all.select { |pm| @frequently_ordered[pm.id] }
    remaining_matches = remaining_all.reject { |pm| @frequently_ordered[pm.id] }

    @grouped_matches = remaining_matches.group_by { |pm| @match_category[pm.id] || "Other" }
    @sorted_categories = @grouped_matches.keys.sort_by { |c| c == "Other" ? "zzz" : c.downcase }

    # Prepend order list section, then frequently ordered
    if order_list_matches.any?
      @order_list_category = "__order_list__"
      @grouped_matches = { @order_list_category => order_list_matches }.merge(@grouped_matches)
      @sorted_categories.unshift(@order_list_category)
    end

    if frequent_matches.any?
      insert_pos = @order_list_category ? 1 : 0
      @grouped_matches["Frequently Ordered"] = frequent_matches
      @sorted_categories.insert(insert_pos, "Frequently Ordered")
    end
  end

  private

  def set_aggregated_list
    @aggregated_list = current_organization_aggregated_lists.find(params[:id])
  end

  def require_not_promoted!
    return unless @aggregated_list&.promoted?

    redirect_to @aggregated_list, alert: "This list is promoted to organization-wide and cannot be edited. Demote it first to make changes."
  end

  # Chefs can only modify lists at their own location
  def require_list_location_access!
    return if current_user.super_admin? || owner?
    return unless @aggregated_list

    if @aggregated_list.location_id != current_location&.id
      redirect_to aggregated_lists_path, alert: "You don't have permission to edit this list."
    end
  end

  def current_organization_aggregated_lists
    if current_user.current_organization
      base = AggregatedList.for_organization(current_user.current_organization)
      # Chefs can only see their own location's lists + any org-wide promoted lists (read-only)
      if chef? && current_location
        base = base.where(location_id: current_location.id).or(base.where(promoted_org_wide: true))
      end
      base
    else
      current_user.created_aggregated_lists
    end
  end

  def available_supplier_lists
    scoped_supplier_lists
      .includes(:supplier)
      .order('suppliers.name ASC, supplier_lists.name ASC')
  end

  def aggregated_list_params
    params.require(:aggregated_list).permit(:name, :description, :list_type)
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
