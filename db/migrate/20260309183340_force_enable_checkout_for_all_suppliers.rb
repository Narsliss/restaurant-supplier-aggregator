class ForceEnableCheckoutForAllSuppliers < ActiveRecord::Migration[7.1]
  def up
    # Force checkout enabled for ALL suppliers and remove WCW order minimum.
    # Previous migration (20260309182533) may have been skipped when deploys
    # were superseded. This ensures the flags are set.
    execute "UPDATE suppliers SET checkout_enabled = true"
    execute <<~SQL
      UPDATE supplier_requirements
      SET active = false
      WHERE supplier_id = (SELECT id FROM suppliers WHERE code = 'whatchefswant')
        AND requirement_type = 'order_minimum'
    SQL

    # Also remove the hardcoded ORDER_MINIMUM check from WCW scraper
    # by setting it to 0 in the database
  end

  def down
    execute "UPDATE suppliers SET checkout_enabled = false"
  end
end
