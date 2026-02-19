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

    new_item = SupplierListItem.find(item_id)
    @product_match_item = @product_match.product_match_items.create!(
      supplier_id: supplier_id,
      supplier_list_item: new_item
    )
    @product_match.update!(match_status: 'manual')

    # Remove duplicate: if this item had its own standalone row, clean it up
    @removed_match_ids = remove_duplicate_rows(new_item.id, @product_match.id)

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

    if new_item_id.blank?
      redirect_back fallback_location: aggregated_list_path(@aggregated_list),
                    alert: 'Please select a product.'
      return
    end

    new_item = SupplierListItem.find(new_item_id)
    @product_match_item.update!(supplier_list_item: new_item)
    @product_match.update!(match_status: 'manual')

    # Remove duplicate: if this item had its own standalone row, clean it up
    @removed_match_ids = remove_duplicate_rows(new_item.id, @product_match.id)

    respond_to do |format|
      format.html do
        redirect_to aggregated_list_path(@aggregated_list),
                    notice: "Updated match: #{new_item.name.truncate(40)}"
      end
      format.turbo_stream
    end
  end

  private

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
