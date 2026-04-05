class ClearBogusChefsPiecePricing < ActiveRecord::Migration[7.1]
  def up
    cw = Supplier.find_by(name: "Chef's Warehouse")
    return unless cw

    # Clear piece_price on supplier_list_items where it equals the case price.
    # The CW API returns the same price for both UOMs when piece ordering
    # isn't actually available for a product, causing a bogus CS/PC toggle.
    SupplierListItem
      .joins(:supplier_list)
      .where(supplier_lists: { supplier_id: cw.id })
      .where("piece_price = price")
      .update_all(piece_price: nil, piece_pack_size: nil)

    # Same for supplier_products
    SupplierProduct
      .where(supplier_id: cw.id)
      .where("piece_price = current_price")
      .update_all(piece_price: nil, piece_pack_size: nil)
  end

  def down
    # Data migration — not reversible
  end
end
