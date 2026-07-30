# frozen_string_literal: true

module Catalog
  # Makes a raw catalog SupplierProduct orderable by giving it the records the
  # ordering pipeline expects: a SupplierListItem on a supplier list mapped to
  # the location's matched list, and a ProductMatch to hang it on.
  #
  # Extracted from CatalogSearchesController#add_to_list (desktop "add to list")
  # so the mobile builder can order a catalog item mid-shift without the chef
  # curating anything. Idempotent: re-adding the same product returns the
  # existing ProductMatch.
  #
  # SAFETY: this only creates catalog/matching records. It never touches order
  # placement, carts, or price verification — a product added here simply
  # arrives as a normal matched product before any ordering logic runs.
  class AddProductToMatchedListService
    class Error < StandardError; end

    attr_reader :supplier_product, :organization, :location, :matched_list

    def initialize(supplier_product:, organization:, location:, matched_list:)
      @supplier_product = supplier_product
      @organization = organization
      @location = location
      @matched_list = matched_list
    end

    # Returns the ProductMatch the product now belongs to.
    def call
      raise Error, "No matched list for this location." unless matched_list
      raise Error, "Supplier not connected." unless supplier_list

      item = supplier_list_item
      existing_match_for(item) || create_match_for(item)
    end

    private

    # The supplier list that will hold the catalog item: prefer one already
    # mapped to the matched list, then any at this location, else create a
    # lightweight catalog list (whose after_create hook maps it).
    def supplier_list
      return @supplier_list if defined?(@supplier_list)

      @supplier_list = matched_list.supplier_lists.find_by(supplier_id: supplier_product.supplier_id)
      return @supplier_list if @supplier_list

      existing = SupplierList.find_by(
        supplier_id: supplier_product.supplier_id,
        location_id: location&.id,
        organization_id: organization.id
      )

      if existing
        matched_list.aggregated_list_mappings.find_or_create_by!(supplier_list: existing)
        return @supplier_list = existing
      end

      @supplier_list = SupplierList.create!(
        supplier_id: supplier_product.supplier_id,
        organization_id: organization.id,
        location_id: location&.id,
        name: "#{supplier_product.supplier.name} (Catalog)",
        list_type: "managed",
        sync_status: "synced"
      )
    end

    def supplier_list_item
      supplier_list.supplier_list_items.find_or_create_by!(supplier_product_id: supplier_product.id) do |item|
        item.name = supplier_product.supplier_name
        item.sku = supplier_product.supplier_sku
        item.price = supplier_product.current_price
        item.pack_size = supplier_product.pack_size
        item.in_stock = supplier_product.in_stock
        item.source = "catalog"
      end
    end

    def existing_match_for(item)
      ProductMatchItem.joins(:product_match)
                      .where(product_matches: { aggregated_list_id: matched_list.id })
                      .where(supplier_list_item_id: item.id)
                      .first
                      &.product_match
    end

    def create_match_for(item)
      match = nil

      ActiveRecord::Base.transaction do
        matched_list.product_matches.update_all("position = position + 1")
        match = matched_list.product_matches.create!(
          canonical_name: supplier_product.supplier_name,
          match_status: "manual",
          confidence_score: 0,
          position: 0
        )
        match.product_match_items.create!(
          supplier_list_item: item,
          supplier_id: supplier_product.supplier_id
        )
      end

      # Cross-supplier matching fills in other suppliers' prices for comparison.
      # Promoted lists are curated org-wide — leave those alone.
      CatalogSearchJob.perform_later(matched_list.id, match_ids: [match.id]) unless matched_list.promoted?

      match
    end
  end
end
