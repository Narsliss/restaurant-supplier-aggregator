class CatalogSearchesController < ApplicationController
  before_action :require_organization!
  before_action :require_operator!
  before_action :require_location_context!

  # GET /catalog_search — HTML search page or JSON results
  def show
    query = params[:q].to_s.strip

    respond_to do |format|
      format.html do
        # Render the search page — results loaded via JS
        @query = query
        @order_lists = scoped_order_lists.order(is_favorite: :desc, last_used_at: :desc)
      end
      format.json do
        return render json: [] if query.length < 2

        results = SupplierProduct
          .where(supplier_id: connected_supplier_ids, discontinued: false)
          .where.not(current_price: nil)
          .where("LOWER(supplier_name) LIKE ?", "%#{query.downcase}%")
          .includes(:supplier)
          .order(:supplier_name)
          .limit(20)

        render json: results.map { |sp| serialize_product(sp) }
      end
    end
  end

  # POST /catalog_search/add_to_list
  def add_to_list
    sp = SupplierProduct.find(params[:supplier_product_id])
    order_list = scoped_order_lists.find(params[:order_list_id])

    # 1. Find or create a supplier list for this supplier on the matched list.
    #    The matched list may not have a mapping for this supplier yet if no
    #    order guide was imported — but the supplier still has catalog products.
    matched_list = current_location_matched_list
    supplier_list = matched_list&.supplier_lists&.find_by(supplier_id: sp.supplier_id)

    # If no supplier list is mapped, look for one at this location or create one
    if supplier_list.nil? && matched_list
      supplier_list = SupplierList.find_by(
        supplier_id: sp.supplier_id,
        location_id: current_location.id,
        organization_id: current_user.current_organization.id
      )

      if supplier_list
        # Link existing supplier list to the matched list
        matched_list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
      else
        # Create a lightweight supplier list for catalog items
        supplier_list = SupplierList.create!(
          supplier_id: sp.supplier_id,
          organization_id: current_user.current_organization.id,
          location_id: current_location.id,
          name: "#{sp.supplier.name} (Catalog)",
          list_type: 'managed',
          sync_status: 'synced'
        )
        # auto_add_to_matched_list callback handles the mapping
      end
    end

    unless supplier_list
      redirect_back fallback_location: root_path, alert: "Supplier not connected."
      return
    end

    # 2. Find or create SupplierListItem from the SupplierProduct
    sli = supplier_list.supplier_list_items.find_or_create_by!(supplier_product_id: sp.id) do |item|
      item.name = sp.supplier_name
      item.sku = sp.supplier_sku
      item.price = sp.current_price
      item.pack_size = sp.pack_size
      item.in_stock = sp.in_stock
      item.source = 'catalog'
    end

    # 3. Find or create ProductMatch on the matched list
    #    Always create so OrderListItem has a product_match_id to reference.
    #    Only run AI cross-supplier matching if the list is NOT promoted.
    product_match = nil
    if matched_list
      existing_pmi = ProductMatchItem.joins(:product_match)
        .where(product_matches: { aggregated_list_id: matched_list.id })
        .where(supplier_list_item_id: sli.id)
        .first

      if existing_pmi
        product_match = existing_pmi.product_match
      else
        matched_list.product_matches.update_all("position = position + 1")
        product_match = matched_list.product_matches.create!(
          canonical_name: sp.supplier_name,
          match_status: 'manual',
          confidence_score: 0,
          position: 0
        )
        product_match.product_match_items.create!(
          supplier_list_item: sli,
          supplier_id: sp.supplier_id
        )
        # Only run AI matching on non-promoted lists
        unless matched_list.promoted?
          CatalogSearchJob.perform_later(matched_list.id, match_ids: [product_match.id])
        end
      end
    end

    # 4. Add to order list
    if product_match
      unless order_list.order_list_items.exists?(product_match_id: product_match.id)
        order_list.order_list_items.create!(product_match_id: product_match.id, quantity: 1)
      end
    elsif sp.product_id
      order_list.add_product!(Product.find(sp.product_id))
    else
      redirect_back fallback_location: root_path, alert: "Could not add product."
      return
    end

    redirect_back fallback_location: root_path,
                  notice: "Added #{sp.supplier_name.truncate(40)} to #{order_list.name}."
  end

  private

  def connected_supplier_ids
    # Include suppliers from both the matched list AND active credentials,
    # since a supplier may have catalog products without an imported order guide.
    ids = Set.new
    matched_list = current_location_matched_list
    ids.merge(matched_list.supplier_lists.pluck(:supplier_id)) if matched_list
    ids.merge(scoped_credentials.active.pluck(:supplier_id))
    ids.to_a
  end

  def current_location_matched_list
    @current_location_matched_list ||= AggregatedList.find_by(
      organization_id: current_user.current_organization.id,
      location_id: current_location.id,
      list_type: %w[master matched]
    )
  end

  def serialize_product(sp)
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
end
