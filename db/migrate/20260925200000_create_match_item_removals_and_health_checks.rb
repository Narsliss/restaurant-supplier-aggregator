class CreateMatchItemRemovalsAndHealthChecks < ActiveRecord::Migration[7.1]
  # Sep 25 2026: deleting a supplier list item cascaded (in Rails AND in this
  # foreign key) to the chef's matched rows, and a routine guide refresh
  # silently emptied confirmed rows. A list item a matched row still uses can
  # no longer be deleted at all; taking a supplier out of matched rows is an
  # explicit step (see MatchedListSupplierRemoval).
  def up
    remove_foreign_key :product_match_items, :supplier_list_items
    add_foreign_key :product_match_items, :supplier_list_items, on_delete: :restrict

    # Nothing recorded what those cascades deleted, so eleven emptied rows could
    # not be rebuilt. Plain columns, no foreign keys: the record outlives the rows.
    create_table :match_item_removals do |t|
      t.bigint :organization_id
      t.bigint :aggregated_list_id
      t.bigint :product_match_id
      t.string :row_name
      t.string :row_status
      t.bigint :supplier_id
      t.bigint :supplier_list_id
      t.bigint :supplier_list_item_id
      t.bigint :supplier_product_id
      t.string :sku
      t.string :item_name
      t.string :cause, null: false
      t.bigint :user_id
      t.datetime :created_at, null: false
    end
    add_index :match_item_removals, [:aggregated_list_id, :created_at]
    add_index :match_item_removals, :product_match_id

    # One row per daily MatchHealthCheckJob run, so the next run can say what's new.
    create_table :match_health_checks do |t|
      t.jsonb :empty_row_ids, null: false, default: []
      t.jsonb :stranded_order_list_item_ids, null: false, default: []
      t.datetime :created_at, null: false
    end
  end

  def down
    drop_table :match_health_checks
    drop_table :match_item_removals
    remove_foreign_key :product_match_items, :supplier_list_items
    add_foreign_key :product_match_items, :supplier_list_items, on_delete: :cascade
  end
end
