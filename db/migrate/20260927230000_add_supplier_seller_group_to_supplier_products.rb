# Sysco groups every seller: LOCAL_SALES (Sysco's own stock), MARKETPLACE
# (third parties like Dot Foods, shipped by the merchant) and SPECIALTY
# ("Special Delivery", e.g. Edward Don). Only LOCAL_SALES belongs on EnPlace:
# the other two can't be modified or cancelled once submitted, ship
# separately, and aren't eligible for returns (Carmin, Sep 27 2026).
# Nullable: blank means "not classified yet".
class AddSupplierSellerGroupToSupplierProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_products, :supplier_seller_group, :string
    add_index :supplier_products, :supplier_seller_group
  end
end
