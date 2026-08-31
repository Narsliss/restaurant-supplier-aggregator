class AddMissedSavingsToOrders < ActiveRecord::Migration[7.1]
  # savings_amount records what the chef beat the market by. Its other half --
  # what they left on the table -- had nowhere to live, so the two sides of one
  # calculation could never be shown together.
  def change
    add_column :orders, :missed_savings_amount, :decimal, precision: 10, scale: 2
  end
end
