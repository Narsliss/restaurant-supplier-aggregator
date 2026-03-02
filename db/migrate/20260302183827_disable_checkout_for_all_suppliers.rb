class DisableCheckoutForAllSuppliers < ActiveRecord::Migration[7.1]
  def up
    # Safety: disable real checkout for ALL suppliers while in testing.
    # Orders will run as dry_run instead of placing real orders.
    execute "UPDATE suppliers SET checkout_enabled = false"
  end

  def down
    # Re-enable for suppliers that previously had it on
    execute <<-SQL
      UPDATE suppliers SET checkout_enabled = true
      WHERE code IN ('usfoods', 'whatchefswant')
    SQL
  end
end
