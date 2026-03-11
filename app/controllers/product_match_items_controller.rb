class ProductMatchItemsController < ApplicationController
  def create
    @product_match = ProductMatch.find(params[:product_match_item][:product_match_id])
    @aggregated_list = @product_match.aggregated_list
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

    respond_to do |format|
      format.html do
        redirect_to aggregated_list_path(@aggregated_list),
                    notice: "Assigned match: #{new_item.name.truncate(40)}"
      end
      format.turbo_stream
    end
  end

  def update
    @product_match_item = ProductMatchItem.find(params[:id])
    @product_match = @product_match_item.product_match
    @aggregated_list = @product_match.aggregated_list

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

    respond_to do |format|
      format.html do
        redirect_to aggregated_list_path(@aggregated_list),
                    notice: "Updated match: #{new_item.name.truncate(40)}"
      end
      format.turbo_stream
    end
  end

  private

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
end
