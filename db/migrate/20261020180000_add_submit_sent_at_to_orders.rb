# Order placement safety (Oct 20 2026, docs/plan-order-placement-double-
# submit-and-account-lock.md). Written and committed right before the live
# submit request goes to the supplier, so a job re-run after a deploy or crash
# knows the order may already be placed and never sends it again. Cleared when
# the chef deliberately starts a new attempt (Order#start_placement!).
class AddSubmitSentAtToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :submit_sent_at, :datetime
  end
end
