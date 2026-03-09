class RemoveAllOrderSafeties < ActiveRecord::Migration[7.1]
  def up
    # Enable real checkout for ALL suppliers (no more dry runs)
    execute "UPDATE suppliers SET checkout_enabled = true"

    # Remove WCW order minimum (chef confirmed there is none)
    execute <<~SQL
      UPDATE supplier_requirements
      SET active = false
      WHERE supplier_id = (SELECT id FROM suppliers WHERE code = 'whatchefswant')
        AND requirement_type = 'order_minimum'
    SQL
  end

  def down
    execute "UPDATE suppliers SET checkout_enabled = false"

    execute <<~SQL
      UPDATE supplier_requirements
      SET active = true
      WHERE supplier_id = (SELECT id FROM suppliers WHERE code = 'whatchefswant')
        AND requirement_type = 'order_minimum'
    SQL
  end
end
