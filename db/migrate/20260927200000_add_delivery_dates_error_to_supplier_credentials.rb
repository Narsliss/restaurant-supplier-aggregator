class AddDeliveryDatesErrorToSupplierCredentials < ActiveRecord::Migration[7.1]
  # A supplier's own reason it offers no delivery dates for this account —
  # e.g. Performance: "You are not currently set up for deliveries. Please
  # contact your Sales Representative." Shown in the order builder and review
  # page so a chef knows before building a cart. Nil when dates were returned.
  def change
    add_column :supplier_credentials, :delivery_dates_error, :string
  end
end
