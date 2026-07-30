class AggregatedListsController < ApplicationController
  include DeliveryDatesRefresher

  before_action :require_location_context!
  before_action :set_aggregated_list, only: %i[show edit update destroy run_matching sync_new_products search_catalog order_builder add_supplier_guide promote demote supplier_items_search catalog_browse add_product builder_catalog_search builder_add_catalog_item]
  before_action :require_owner!, only: %i[promote demote]
  before_action :require_not_promoted!, only: %i[edit update destroy run_matching sync_new_products add_supplier_guide add_product]
  before_action :require_list_location_access!, only: %i[edit update destroy run_matching sync_new_products add_supplier_guide catalog_browse add_product]

  # Mobile "Order" tab entry point: resolve straight to the user's primary
  # order builder (promoted org-wide list, else their location's matched list).
  # Falls back to the list picker when nothing is matched yet.
  def start_order
    matched = current_organization_aggregated_lists.matched_lists.where(match_status: "matched")
    list = matched.find(&:promoted?) ||
           (current_location && matched.find { |l| l.location_id == current_location.id }) ||
           matched.first
    if list
      # The chef's working order (CurrentOrder) is the builder's only source
      # of truth — no batch resume: prefilling from an in-progress cart could
      # resurrect items the chef explicitly cleared from their Order.
      redirect_to order_builder_aggregated_list_path(list)
    else
      redirect_to select_list_orders_path
    end
  end

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
                                       .where.not(match_status: 'rejected')
                                       .includes(:canonical_image_supplier_product,
                                                 product_match_items: [:supplier, { supplier_list_item: [:supplier_product, :supplier_list] }])
                                       .order(Arel.sql("CASE match_status WHEN 'confirmed' THEN 0 WHEN 'manual' THEN 1 WHEN 'auto_matched' THEN 2 WHEN 'unmatched' THEN 3 ELSE 4 END, position ASC"))

    # @suppliers is the union of (suppliers with a list in this agg) and
    # (suppliers with a credential at this list's location). Credential-based
    # inclusion guarantees a chef sees a column for every supplier they're set
    # up with — even before any list has been scraped or when the supplier
    # side has no order guides yet. Cells without a ProductMatchItem render
    # empty, ready for the chef to drop matches into.
    list_supplier_ids = @supplier_lists.map(&:supplier_id).uniq
    credentialed_supplier_ids = if @aggregated_list.location_id.present?
      SupplierCredential.where(
        organization_id: @aggregated_list.organization_id,
        location_id: @aggregated_list.location_id
      ).pluck(:supplier_id).uniq
    else
      []
    end
    @suppliers = sort_suppliers_for_user(
      Supplier.where(id: (list_supplier_ids + credentialed_supplier_ids).uniq).to_a
    )

    # Pre-compute stats with a single grouped query instead of 3 separate COUNTs
    # Exclude rejected matches — they're hidden from the user (recoverable via Re-match All)
    status_counts = @aggregated_list.product_matches.where.not(match_status: 'rejected').group(:match_status).count
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

      in_stock_prices = prices.select { |p| p[:price].present? && p[:price] > 0 && p[:in_stock] }

      # Prefer per-unit comparison: find items with per-unit prices and matching units.
      # Treat "oz" and "fl oz" as equivalent for comparison (close enough in food service).
      with_per_unit = in_stock_prices.select { |p| p[:per_unit_price].present? && p[:per_unit_price] > 0 && p[:normalized_unit].present? }
      unit_groups = with_per_unit.group_by { |p| p[:normalized_unit] == "fl oz" ? "oz" : p[:normalized_unit] }
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

      with_price = prices.select { |p| p[:price].present? && p[:price] > 0 }
      spread = nil
      if with_price.size >= 2
        per_unit_with_price = with_price.select { |p| p[:per_unit_price].present? && p[:per_unit_price] > 0 && p[:normalized_unit].present? }
        price_unit_groups = per_unit_with_price.group_by { |p| p[:normalized_unit] == "fl oz" ? "oz" : p[:normalized_unit] }
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

    # Teaser columns: show catalog data from suppliers not mapped to this list.
    # Primary source is the teaser_matches table, populated by TeaserCatalogSearchJob
    # via name-similarity matching across the full catalog. Falls back to the
    # canonical-Product-id JOIN when teaser_matches is empty for this list
    # (e.g. before the backfill job has run, or for a brand-new list awaiting
    # its first matching pass).
    connected_ids = @suppliers.map(&:id)
    @unconnected_suppliers = Supplier.where(active: true).where.not(id: connected_ids).order(:name)
    @teaser_map = {}

    if @unconnected_suppliers.any?
      teaser_records = TeaserMatch.where(aggregated_list_id: @aggregated_list.id)
                                  .includes(:supplier_product)
                                  .to_a

      if teaser_records.any?
        teaser_records.each do |tm|
          @teaser_map[tm.product_match_id] ||= {}
          @teaser_map[tm.product_match_id][tm.supplier_id] ||= tm.supplier_product
        end
      else
        # Fallback path: canonical Product link join (the pre-teaser-matches
        # behavior). Keeps the page useful for lists that haven't been
        # processed by TeaserCatalogSearchJob yet.
        match_product_ids = {}
        @product_matches.each do |match|
          match.product_match_items.each do |pmi|
            pid = pmi.supplier_list_item.supplier_product&.product_id
            next unless pid
            match_product_ids[match.id] ||= pid
          end
        end

        if match_product_ids.values.any?
          unconnected_ids = @unconnected_suppliers.map(&:id)
          teaser_by_product_and_supplier = {}
          SupplierProduct
            .where(supplier_id: unconnected_ids, product_id: match_product_ids.values.uniq, discontinued: false)
            .select(:id, :supplier_id, :product_id, :supplier_name, :pack_size, :current_price, :price_unit, :in_stock)
            .each do |sp|
              teaser_by_product_and_supplier[sp.product_id] ||= {}
              teaser_by_product_and_supplier[sp.product_id][sp.supplier_id] ||= sp
            end

          match_product_ids.each do |match_id, product_id|
            @teaser_map[match_id] = teaser_by_product_and_supplier[product_id] || {}
          end
        end
      end

      # Only show columns for suppliers that have at least one teaser
      @unconnected_suppliers = @unconnected_suppliers.select do |supplier|
        @teaser_map.values.any? { |supplier_map| supplier_map.key?(supplier.id) }
      end
    end

    # --- Category grouping for show page ---
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

      if normalized.blank?
        name = pm.canonical_name.presence || pm.product_match_items.first&.supplier_list_item&.name
        if name.present?
          result = AiProductCategorizer.rule_based_categorize(name)
          normalized = result[:category] if result[:confidence] >= 0.7
        end
      end

      @match_category[pm.id] = normalized
    end

    @grouped_matches = @product_matches.group_by { |pm| @match_category[pm.id] || "Other" }
    @sorted_categories = @grouped_matches.keys.sort_by { |c| c == "Other" ? "zzz" : c.downcase }

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
        redirect_to aggregated_lists_path
      else
        redirect_to @aggregated_list
      end
    else
      if params[:return_to] == "supplier_lists"
        redirect_to aggregated_lists_path
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
    # Restore the location-based name when demoting back to a location list
    attrs = { promoted_org_wide: false }
    if @aggregated_list.location_id.present?
      location = Location.find_by(id: @aggregated_list.location_id)
      attrs[:name] = "#{location.name} Matched List" if location
    end
    @aggregated_list.update!(attrs)
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
    # Deduplicate across multiple supplier lists — pick the most recently updated entry per product
    guide_results = guide_items.select("DISTINCT ON (COALESCE(supplier_product_id, id)) id, name, price, pack_size, supplier_product_id")
                               .order(Arel.sql("COALESCE(supplier_product_id, id), updated_at DESC"))

    # Track which catalog products are already covered by order guide items
    covered_product_ids = guide_results.filter_map(&:supplier_product_id).to_set

    # 2. Full catalog items (not on any order guide) — these use supplier_product: prefix
    catalog = SupplierProduct.where(supplier_id: supplier_id, discontinued: false)
    catalog = catalog.where("LOWER(supplier_name) LIKE ?", "%#{query}%") if query.present?
    catalog = catalog.where.not(id: covered_product_ids.to_a) if covered_product_ids.any?
    catalog_results = catalog.select(:id, :supplier_name, :current_price, :pack_size)
                             .order(:supplier_name)

    json = guide_results.map { |i|
      { id: i.id, name: i.name.truncate(60), price: i.price ? "$#{'%.2f' % i.price}" : "N/A", pack_size: i.pack_size, source: "guide" }
    }
    json += catalog_results.map { |sp|
      { id: "sp_#{sp.id}", name: sp.supplier_name.truncate(60), price: sp.current_price ? "$#{'%.2f' % sp.current_price}" : "N/A", pack_size: sp.pack_size, source: "catalog" }
    }

    render json: json
  end

  def search_catalog
    unless @aggregated_list.matched? || @aggregated_list.match_status == 'failed'
      redirect_to @aggregated_list
      return
    end

    @aggregated_list.mark_searching_catalog!
    CatalogSearchJob.perform_later(@aggregated_list.id)
    redirect_to @aggregated_list
  end

  # --- Mobile builder: "Everything else" full-catalog search -----------------
  # Chefs must be able to order what they need mid-shift whether or not it has
  # been curated onto a list. This searches every connected supplier's catalog
  # (76K+ products, ~20ms) and deliberately runs a WIDE net — no small cap;
  # chefs narrow by typing more ("truffle oil" not "truffle").

  # A backstop so a 1-2 character query can't push thousands of rows into the
  # DOM. The response reports the true total so the UI can say what's hidden.
  CATALOG_RESULT_CAP = 500

  # GET /aggregated_lists/:id/builder_catalog_search?q=
  def builder_catalog_search
    query = params[:q].to_s.strip
    return render json: { results: [], total: 0, capped: false } if query.length < 2

    connected = scoped_credentials.active.distinct.pluck(:supplier_id)
    return render json: { results: [], total: 0, capped: false } if connected.empty?

    # Exclude anything already rendered in the two matched-list sections
    on_list = SupplierListItem
      .joins(product_match_items: :product_match)
      .where(product_matches: { aggregated_list_id: @aggregated_list.id })
      .where.not(supplier_product_id: nil)
      .select(:supplier_product_id)

    scope = SupplierProduct
      .where(supplier_id: connected, discontinued: false)
      .where.not(current_price: nil)
      .where("LOWER(supplier_name) LIKE ?", "%#{query.downcase}%")
      .where.not(id: on_list)

    total = scope.count
    products = scope.includes(:supplier)
                    .order(Arel.sql("LOWER(supplier_name)"))
                    .limit(CATALOG_RESULT_CAP)

    render json: {
      results: products.map { |sp| catalog_result_payload(sp) },
      total: total,
      capped: total > CATALOG_RESULT_CAP
    }
  end

  # POST /aggregated_lists/:id/builder_add_catalog_item
  # Makes a catalog product orderable and returns everything the builder needs
  # to render it as a normal card, so it flows through the untouched ordering
  # pipeline like any other matched product.
  def builder_add_catalog_item
    sp = SupplierProduct.find_by(id: params[:supplier_product_id])
    return render json: { error: "Product not found." }, status: :not_found unless sp

    connected = scoped_credentials.active.distinct.pluck(:supplier_id)
    unless connected.include?(sp.supplier_id)
      return render json: { error: "You don't have an active login for #{sp.supplier.name}." }, status: :forbidden
    end

    match = Catalog::AddProductToMatchedListService.new(
      supplier_product: sp,
      organization: current_user.current_organization,
      location: current_location,
      matched_list: @aggregated_list
    ).call

    render json: added_card_payload(match, sp)
  rescue Catalog::AddProductToMatchedListService::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def order_builder
    # Auto-heal: if status is 'failed' but matches exist, restore to 'matched'
    if @aggregated_list.match_status == 'failed' && @aggregated_list.product_matches.any?
      @aggregated_list.mark_matched!
    end

    unless @aggregated_list.matched?
      redirect_to @aggregated_list
      return
    end

    @product_matches = @aggregated_list.product_matches
                                       .where.not(match_status: 'rejected')
                                       .includes(:canonical_image_supplier_product,
                                                 product_match_items: [:supplier, { supplier_list_item: [:supplier_product, :supplier_list] }])
                                       .order(Arel.sql("CASE match_status WHEN 'confirmed' THEN 0 WHEN 'manual' THEN 1 WHEN 'auto_matched' THEN 2 WHEN 'unmatched' THEN 3 ELSE 4 END, position ASC"))
    # Show suppliers the user has active credentials for, plus email suppliers (no credentials needed)
    available_supplier_ids = scoped_credentials.active.pluck(:supplier_id).to_set
    @suppliers = sort_suppliers_for_user(
      @aggregated_list.suppliers.select { |s| available_supplier_ids.include?(s.id) || s.email_supplier? }
    )

    # Matches on ANY of the user's order lists — search results surface these
    # first in their own section (chef punch item), regardless of which list
    # (if any) the builder was entered through.
    @all_list_match_ids = scoped_order_lists
      .joins(:order_list_items)
      .where.not(order_list_items: { product_match_id: nil })
      .pluck("order_list_items.product_match_id")
      .to_set

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

    # Delivery info for suppliers (used by date picker validation)
    # Two sources: API-fetched dates (Sysco) and manual schedules (other suppliers)
    @delivery_schedules_by_supplier = SupplierDeliverySchedule
      .where(supplier_id: supplier_ids, active: true)
      .for_location(current_location)
      .order(:day_of_week)
      .group_by(&:supplier_id)

    # API-fetched available delivery dates from credentials (e.g., Sysco).
    # We read whatever's currently stored — the refresh below runs async and
    # will update the DB in place; the next page load picks it up.
    api_capable_credentials = scoped_credentials.active
                                                .where(supplier_id: supplier_ids)
                                                .includes(:supplier)
                                                .to_a
    @api_delivery_dates_by_supplier = {}
    api_capable_credentials.each do |cred|
      next if cred.available_delivery_dates.blank?

      @api_delivery_dates_by_supplier[cred.supplier_id] = {
        dates: cred.available_delivery_dates,
        fetched_at: cred.delivery_dates_fetched_at
      }
    end

    # Auto-refresh: if any Sysco credential's dates are stale (>4h) or missing,
    # kick off a background refetch. No UI prompt, no chef action — the dates
    # either update silently for the next page load, or the user proceeds with
    # the slightly-stale cache (the submit-time validation catches any drift).
    refresh_stale_delivery_dates!(api_capable_credentials)

    # Pre-fill quantities from existing pending/draft/verifying batch orders (when returning from review page).
    # Draft orders are what a completed verification produces; also include verifying & price_changed
    @quantities = {}
    @prefill_suppliers = {}  # match_id(str) → supplier_id (mobile: restore the chef's actual pick, not cheapest)
    @prefill_uoms = {}       # match_id(str) → "CS"/"PC"
    @delivery_date = nil
    @batch_id = params[:batch_id].presence

    # The chef's singular working order (CurrentOrder) is the builder's ONLY
    # prefill source. Deliberately no batch fallback: prefilling from an
    # in-progress cart resurrected items the chef had explicitly cleared from
    # their Order (chef bug report 2026-07-29, flat leaf parsley).
    current_order = CurrentOrder.find_by(user: current_user, aggregated_list: @aggregated_list)
    if current_order && !current_order.empty?
      @delivery_date = current_order.delivery_date
      current_order.sanitized_state.each do |match_id, entry|
        @quantities[match_id] = entry["qty"]
        @prefill_suppliers[match_id] = entry["supplierId"].to_i
        @prefill_uoms[match_id] = entry["uom"] if entry["uom"].present?
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
    # Per-product order counts, exposed to the builder for the
    # minimum-suggestion sheet ("you usually order this from X")
    @ordered_counts = frequency_counts

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

  def catalog_browse
    query = params[:q].to_s.strip
    return render json: [] if query.length < 2

    connected_supplier_ids = @aggregated_list.supplier_lists.pluck(:supplier_id)

    results = SupplierProduct
      .where(supplier_id: connected_supplier_ids, discontinued: false)
      .where.not(current_price: nil)
      .where("LOWER(supplier_name) LIKE ?", "%#{query.downcase}%")
      .includes(:supplier)
      .order(:supplier_name)
      .limit(20)

    json = results.map do |sp|
      {
        id: sp.id,
        name: sp.supplier_name.truncate(60),
        price: sp.current_price ? "$#{'%.2f' % sp.current_price}" : "N/A",
        pack_size: sp.pack_size,
        supplier_name: sp.supplier.name,
        supplier_id: sp.supplier_id,
        in_stock: sp.in_stock
      }
    end

    render json: json
  end

  def add_product
    sp = SupplierProduct.find(params[:supplier_product_id])

    supplier_list = @aggregated_list.supplier_lists
                                    .where(supplier_id: sp.supplier_id)
                                    .first

    unless supplier_list
      redirect_to @aggregated_list, alert: "Supplier not connected to this list."
      return
    end

    item = supplier_list.supplier_list_items.find_or_create_by!(supplier_product_id: sp.id) do |sli|
      sli.name = sp.supplier_name
      sli.sku = sp.supplier_sku
      sli.price = sp.current_price
      sli.pack_size = sp.pack_size
      sli.in_stock = sp.in_stock
      sli.source = 'catalog'
    end

    existing_pmi = ProductMatchItem.joins(:product_match)
      .where(product_matches: { aggregated_list_id: @aggregated_list.id })
      .where(supplier_list_item_id: item.id)
      .first

    if existing_pmi
      redirect_to @aggregated_list, notice: "#{sp.supplier_name.truncate(40)} is already on this list."
      return
    end

    @aggregated_list.product_matches.update_all("position = position + 1")
    match = @aggregated_list.product_matches.create!(
      canonical_name: sp.supplier_name,
      match_status: 'manual',
      confidence_score: 0,
      position: 0
    )
    match.product_match_items.create!(
      supplier_list_item: item,
      supplier_id: sp.supplier_id
    )

    # Search catalog for matches from other connected suppliers
    CatalogSearchJob.perform_later(@aggregated_list.id, match_ids: [match.id])

    # Refresh teaser cells for the new row (non-credentialed supplier columns)
    TeaserCatalogSearchJob.perform_later(@aggregated_list.id)

    redirect_to @aggregated_list, notice: "Added #{sp.supplier_name.truncate(40)} to list. Searching for matches..."
  end

  private

  # A chef can hold a link to another restaurant's list (a bookmark, or the URL
  # Devise stored before they signed in). Raising RecordNotFound dead-ended them
  # on an error page with no way back, so redirect to something they CAN use.
  # One "Everything else" row: a catalog product the chef can tap to order.
  def catalog_result_payload(sp)
    {
      supplier_product_id: sp.id,
      name: sp.supplier_name.to_s,
      supplier: sp.supplier.short_name,
      supplier_id: sp.supplier_id,
      pack_size: sp.pack_size.to_s,
      # estimated_case_price: catch-weight products store price per LB
      price: sp.estimated_case_price.to_f.round(2),
      price_display: helpers.number_to_currency(sp.estimated_case_price),
      per_unit: sp.formatted_comparison_per_oz,
      in_stock: sp.in_stock?
    }
  end

  # Everything the mobile builder needs to inject a real card for a product it
  # just made orderable — mirrors the data attributes order_builder renders.
  def added_card_payload(match, sp)
    item = match.product_match_items
                .map(&:supplier_list_item)
                .compact
                .find { |sli| sli.supplier_product_id == sp.id }

    price = item&.estimated_total_price || item&.price || sp.estimated_case_price
    piece = item&.piece_price if item&.piece_price.present? && item.piece_price.positive?

    {
      match_id: match.id,
      display_name: match.display_name.to_s,
      category: ::CategoryNormalizable.normalize(sp.product&.category).presence || "Other",
      thumb: helpers.product_thumb_url(sp), # display-only: never triggers a supplier fetch
      supplier_id: sp.supplier_id,
      short: sp.supplier.short_name,
      price: price.to_f.round(2),
      price_display: helpers.number_to_currency(price),
      per_unit: item&.catch_weight_note || item&.formatted_per_unit_price,
      pack: (item&.pack_size.presence || sp.pack_size).to_s,
      piece_price: piece&.to_f,
      piece_display: piece ? helpers.number_to_currency(piece) : nil,
      in_stock: sp.in_stock?
    }
  end

  def set_aggregated_list
    @aggregated_list = current_organization_aggregated_lists.find_by(id: params[:id])
    return if @aggregated_list

    fallback = current_organization_aggregated_lists.matched_lists.first
    message = "That list belongs to another restaurant. " \
              "#{fallback ? 'Here is your list instead.' : 'Pick a restaurant from the menu to continue.'}"

    redirect_to(fallback ? order_builder_aggregated_list_path(fallback) : root_path, alert: message)
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
