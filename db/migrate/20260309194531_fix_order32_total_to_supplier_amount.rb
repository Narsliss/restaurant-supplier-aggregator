class FixOrder32TotalToSupplierAmount < ActiveRecord::Migration[7.1]
  def up
    # CW reported $406.40 as the actual cart total
    execute <<~SQL
      UPDATE orders
      SET total_amount = 406.40, subtotal = 406.40
      WHERE id = 32
    SQL
  end

  def down
    # One-time data fix
  end
end
