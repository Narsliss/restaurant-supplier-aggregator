class AddPromotedOrgWideToAggregatedLists < ActiveRecord::Migration[7.1]
  def change
    add_column :aggregated_lists, :promoted_org_wide, :boolean, default: false, null: false
  end
end
