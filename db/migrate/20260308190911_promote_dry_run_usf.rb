class PromoteDryRunUsf < ActiveRecord::Migration[7.1]
  def up
    # The US Foods dry-run order was a real submission — promote it to confirmed
    usf = Supplier.find_by(name: "US Foods")
    return unless usf

    Order.where(supplier: usf, status: "dry_run_complete")
         .where("confirmation_number LIKE ?", "DRY-RUN%")
         .update_all(status: "confirmed")
  end

  def down
    # no-op: can't reliably reverse
  end
end
