# Sysco's site lists items from other sellers (e.g. Dole pineapple under
# seller "2011") beside its own ("USBL"). Pricing, price checks and cart lines
# must name the item's own seller or Sysco returns nothing / rejects the line.
# Nullable: blank means "not known yet" and falls back to the account's seller.
class AddSupplierSellerIdToSupplierProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_products, :supplier_seller_id, :string
  end
end
