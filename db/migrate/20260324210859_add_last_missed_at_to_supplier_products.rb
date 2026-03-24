class AddLastMissedAtToSupplierProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_products, :last_missed_at, :datetime
  end
end
