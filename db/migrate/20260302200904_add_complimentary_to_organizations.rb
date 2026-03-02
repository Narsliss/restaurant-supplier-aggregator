class AddComplimentaryToOrganizations < ActiveRecord::Migration[7.1]
  def change
    add_column :organizations, :complimentary, :boolean, default: false, null: false
    add_column :organizations, :complimentary_reason, :string
    add_column :organizations, :complimentary_granted_at, :datetime
    add_column :organizations, :complimentary_granted_by_id, :bigint
  end
end
