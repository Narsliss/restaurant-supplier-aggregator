class MakeOrganizationOptionalOnAggregatedLists < ActiveRecord::Migration[7.1]
  def change
    change_column_null :aggregated_lists, :organization_id, true
  end
end
