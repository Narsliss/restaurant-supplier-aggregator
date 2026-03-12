class AddListTypeToAggregatedLists < ActiveRecord::Migration[7.1]
  def up
    unless column_exists?(:aggregated_lists, :location_id)
      add_reference :aggregated_lists, :location, foreign_key: { on_delete: :nullify }
    end

    unless column_exists?(:aggregated_lists, :list_type)
      add_column :aggregated_lists, :list_type, :string, default: "custom", null: false
    end

    unless column_exists?(:aggregated_lists, :auto_sync)
      add_column :aggregated_lists, :auto_sync, :boolean, default: false, null: false
    end

    unless column_exists?(:aggregated_lists, :shared_across_org)
      add_column :aggregated_lists, :shared_across_org, :boolean, default: false, null: false
    end

    unless index_exists?(:aggregated_lists, [:organization_id, :list_type, :location_id], name: "idx_aggregated_lists_master_unique")
      add_index :aggregated_lists, [:organization_id, :list_type, :location_id],
                name: "idx_aggregated_lists_master_unique",
                unique: true,
                where: "list_type = 'master'"
    end
  end

  def down
    remove_index :aggregated_lists, name: "idx_aggregated_lists_master_unique", if_exists: true
    remove_column :aggregated_lists, :shared_across_org, if_exists: true
    remove_column :aggregated_lists, :auto_sync, if_exists: true
    remove_column :aggregated_lists, :list_type, if_exists: true
    remove_reference :aggregated_lists, :location, if_exists: true
  end
end
