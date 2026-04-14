class AddAvailableDeliveryDatesToSupplierCredentials < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_credentials, :available_delivery_dates, :jsonb, default: []
    add_column :supplier_credentials, :delivery_dates_fetched_at, :datetime
  end
end
