class AddBaselineMatchProvenance < ActiveRecord::Migration[7.1]
  def change
    # Provenance on the global spine link. Existing links have NULL source
    # (legacy import matcher); the baseline apply stamps "claude_baseline".
    add_column :supplier_products, :match_source, :string
    add_column :supplier_products, :match_confidence, :string
    add_index :supplier_products, :match_source

    # Reversibility: one row per product_id we repoint (supplier_products AND
    # order_list_items — see below), capturing the prior product_id so the whole
    # run rolls back with one task. Generic (record_type/record_id) because the
    # apply must also fix OrderList items whose Product gets emptied, or the
    # OrderList order builder would resolve them to nil.
    create_table :baseline_link_snapshots do |t|
      t.string :record_type, null: false
      t.bigint :record_id, null: false
      t.bigint :previous_product_id
      t.string :run_tag, null: false
      t.timestamps
    end
    add_index :baseline_link_snapshots, [:run_tag, :record_type, :record_id],
              unique: true, name: "index_baseline_snapshots_on_run_and_record"
  end
end
