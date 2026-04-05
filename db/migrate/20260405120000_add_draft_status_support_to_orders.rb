class AddDraftStatusSupportToOrders < ActiveRecord::Migration[7.1]
  def up
    add_column :orders, :draft_saved_at, :datetime

    # Backfill: convert existing verified-pending orders that were never submitted to draft
    execute <<-SQL
      UPDATE orders
      SET status = 'draft', draft_saved_at = COALESCE(price_verified_at, NOW())
      WHERE status = 'pending'
        AND verification_status IN ('verified', 'skipped')
        AND submitted_at IS NULL
        AND price_verified_at IS NOT NULL
    SQL
  end

  def down
    execute "UPDATE orders SET status = 'pending' WHERE status = 'draft'"
    remove_column :orders, :draft_saved_at
  end
end
