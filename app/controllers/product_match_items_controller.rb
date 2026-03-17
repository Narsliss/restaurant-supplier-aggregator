class ProductMatchItemsController < ApplicationController
  before_action :require_location_context!
  before_action :set_aggregated_list_from_match
  before_action :require_list_write_access!

  def create
    supplier_id = params[:product_match_item][:supplier_id]
    item_id = params[:product_match_item][:supplier_list_item_id]

    if item_id.blank?
      redirect_back fallback_location: aggregated_list_path(@aggregated_list),
                    alert: 'Please select a product.'
      return
    end

    new_item = resolve_supplier_list_item(item_id, supplier_id)
    @product_match_item = @product_match.product_match_items.create!(
      supplier_id: supplier_id,
      supplier_list_item: new_item
    )
    @product_match.update!(match_status: 'manual')

    # Remove duplicate: if this item had its own standalone row, clean it up
    @removed_match_ids = remove_duplicate_rows(new_item.id, @product_match.id)

    @supplier = Supplier.find(supplier_id)
    prepare_turbo_row_data(@product_match)

    respond_to do |format|
      format.html do
        redirect_to aggregated_list_path(@aggregated_list),
                    notice: "Assigned match: #{new_item.name.truncate(40)}"
      end
      format.turbo_stream
    end
  end

  def update
    new_item_id = params.dig(:product_match_item, :supplier_list_item_id)

    # "No Match" — user wants to remove this supplier's item from the match group
    if new_item_id.blank?
      old_item = @product_match_item.supplier_list_item
      @old_supplier = @product_match_item.supplier
      @product_match_item.destroy!

      # If the match now has zero or one assigned items, update status
      remaining = @product_match.product_match_items.reload.count
      if remaining == 0
        @product_match.destroy!
        @product_match_destroyed = true
      else
        @product_match.update!(match_status: remaining <= 1 ? 'unmatched' : 'manual')
      end

      # Create a standalone unmatched row for the orphaned item so it doesn't vanish
      @new_orphan_match = nil
      if old_item
        max_pos = @aggregated_list.product_matches.maximum(:position) || 0
        @new_orphan_match = @aggregated_list.product_matches.create!(
          canonical_name: old_item.name,
          match_status: 'unmatched',
          confidence_score: 0,
          position: max_pos + 1
        )
        @new_orphan_match.product_match_items.create!(
          supplier_list_item: old_item,
          supplier: @old_supplier
        )
      end

      respond_to do |format|
        format.html do
          redirect_to aggregated_list_path(@aggregated_list),
                      notice: "Removed match#{old_item ? ": #{old_item.name.truncate(40)}" : ''}"
        end
        format.turbo_stream { render :no_match }
      end
      return
    end

    new_item = resolve_supplier_list_item(new_item_id, @product_match_item.supplier_id)
    @product_match_item.update!(supplier_list_item: new_item)
    @product_match.update!(match_status: 'manual')

    # Remove duplicate: if this item had its own standalone row, clean it up
    @removed_match_ids = remove_duplicate_rows(new_item.id, @product_match.id)

    @supplier = @product_match_item.supplier
    prepare_turbo_row_data(@product_match)

    respond_to do |format|
      format.html do
        redirect_to aggregated_list_path(@aggregated_list),
                    notice: "Updated match: #{new_item.name.truncate(40)}"
      end
      format.turbo_stream
    end
  end

  private

  # Locate the aggregated list (with org scoping) from the match or item being acted on.
  # For create: the product_match_id comes from params.
  # For update: the product_match_item ID comes from params[:id].
  def set_aggregated_list_from_match
    org = current_user.current_organization
    base = org ? AggregatedList.for_organization(org) : AggregatedList.none
    if chef? && current_location
      base = base.where(location_id: current_location.id).or(base.where(promoted_org_wide: true))
    end

    if action_name == 'create'
      @product_match = ProductMatch.find(params[:product_match_item][:product_match_id])
      @aggregated_list = base.find(@product_match.aggregated_list_id)
    else
      @product_match_item = ProductMatchItem.find(params[:id])
      @product_match = @product_match_item.product_match
      @aggregated_list = base.find(@product_match.aggregated_list_id)
    end
  end

  # Chefs can only modify lists at their own location; nobody can modify promoted lists
  def require_list_write_access!
    return unless @aggregated_list

    if @aggregated_list.promoted?
      redirect_to aggregated_list_path(@aggregated_list), alert: "This list is read-only (promoted org-wide)."
      return
    end

    return if current_user.super_admin? || owner?

    if @aggregated_list.location_id != current_location&.id
      redirect_to root_path, alert: "You don't have permission to modify this list."
    end
  end

  # Resolve an item ID to a SupplierListItem. If the ID is prefixed with "sp_",
  # it's a catalog product (SupplierProduct) — find or create a SupplierListItem
  # on the first supplier list for that supplier in the aggregated list.
  def resolve_supplier_list_item(item_id, supplier_id)
    if item_id.to_s.start_with?("sp_")
      sp = SupplierProduct.find(item_id.to_s.delete_prefix("sp_"))
      supplier_list = @aggregated_list.supplier_lists
                                      .where(supplier_id: supplier_id)
                                      .first

      # Find existing SupplierListItem linked to this catalog product, or create one
      existing = supplier_list.supplier_list_items.find_by(supplier_product_id: sp.id) if supplier_list
      return existing if existing

      supplier_list.supplier_list_items.create!(
        supplier_product_id: sp.id,
        name: sp.supplier_name,
        sku: sp.supplier_sku,
        price: sp.current_price,
        pack_size: sp.pack_size,
        in_stock: sp.in_stock,
        source: 'catalog'
      )
    else
      SupplierListItem.find(item_id)
    end
  end

  # When a supplier_list_item is assigned to a match row, find any OTHER
  # ProductMatch rows in the same aggregated list that contain this same item.
  # Remove the item from those rows, and destroy any rows left with zero items.
  # Returns an array of destroyed ProductMatch IDs (for Turbo Stream removal).
  def remove_duplicate_rows(supplier_list_item_id, keep_match_id)
    removed_ids = []

    duplicate_pmis = ProductMatchItem
      .joins(:product_match)
      .where(supplier_list_item_id: supplier_list_item_id)
      .where(product_matches: { aggregated_list_id: @aggregated_list.id })
      .where.not(product_match_id: keep_match_id)

    duplicate_pmis.each do |dup_pmi|
      parent = dup_pmi.product_match
      dup_pmi.destroy

      # If that was the last item on the row, remove the entire row
      if parent.product_match_items.reload.empty?
        removed_ids << parent.id
        parent.destroy
      end
    end

    removed_ids
  end

  # Compute price comparison + supplier map for a single match row.
  # Only loads items already on the match — no extra queries per supplier.
  def prepare_turbo_row_data(match)
    @suppliers = @aggregated_list.supplier_lists.includes(:supplier).map(&:supplier).uniq
    @total_supplier_cols = @suppliers.size

    # Build supplier map for this one match
    supplier_map = {}
    match.product_match_items.reload.includes(:supplier, :supplier_list_item).each do |pmi|
      supplier_map[pmi.supplier_id] = { pmi: pmi, item: pmi.supplier_list_item }
    end
    @match_supplier_map = { match.id => supplier_map }

    # Compute price comparison for this one match
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
    with_per_unit = in_stock_prices.select { |p| p[:per_unit_price].present? && p[:normalized_unit].present? }
    unit_groups = with_per_unit.group_by { |p| p[:normalized_unit] }
    largest_group = unit_groups.max_by { |_unit, items| items.size }&.last || []

    cheapest = most_expensive = nil
    if largest_group.size >= 2
      cheapest = largest_group.min_by { |p| p[:per_unit_price] }
      most_expensive = largest_group.max_by { |p| p[:per_unit_price] }
    elsif in_stock_prices.any?
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

    @price_info = {
      cheapest_supplier: cheapest&.dig(:supplier),
      most_expensive_supplier: most_expensive&.dig(:supplier),
      spread: spread
    }
  end
end
