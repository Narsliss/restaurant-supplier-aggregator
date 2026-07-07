class AddSupplierExceptionsToOrders < ActiveRecord::Migration[7.1]
  def change
    # Normalized list of post-submission issues the supplier flagged
    # (out of stock, substituted, short-filled, price change). Empty = clean.
    add_column :orders, :supplier_exceptions, :jsonb, default: [], null: false
    add_column :orders, :exceptions_checked_at, :datetime
  end
end
