# Morning stock run, plan Phase 3 (Oct 2026). Record what each supplier said
# about an item's stock and when (we only kept true/false, so "what did CW say
# at 8 AM?" was unanswerable), plus a per-supplier switch on the Operations
# page: live = the morning run marks items out AND back in (the default —
# Carmin, Oct 19: no two-morning shadow; a guard holds a run that reads an
# implausible share out), shadow = record only, off = record nothing.
class AddStockEvidence < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_products, :stock_signal, :string
    add_column :supplier_products, :stock_checked_at, :datetime
    add_column :supplier_products, :stock_source, :string

    add_column :suppliers, :morning_stock_mode, :string, null: false, default: "live"
    add_column :suppliers, :last_stock_run, :jsonb
  end
end
