class AddCasePricingToSuppliers < ActiveRecord::Migration[7.1]
  def change
    add_column :suppliers, :case_pricing, :boolean, default: true, null: false
  end
end
