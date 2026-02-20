class AddPriceVerificationToOrders < ActiveRecord::Migration[7.1]
  def change
    # Order-level verification tracking
    add_column :orders, :verification_status, :string, default: nil
    add_column :orders, :price_verified_at, :datetime
    add_column :orders, :verified_total, :decimal, precision: 10, scale: 2
    add_column :orders, :price_change_amount, :decimal, precision: 10, scale: 2
    add_column :orders, :verification_error, :text

    # Order-item-level verified prices (what the supplier actually charges now)
    add_column :order_items, :verified_price, :decimal, precision: 10, scale: 2

    add_index :orders, :verification_status
  end
end
