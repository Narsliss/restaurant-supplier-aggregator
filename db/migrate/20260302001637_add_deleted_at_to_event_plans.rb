class AddDeletedAtToEventPlans < ActiveRecord::Migration[7.1]
  def change
    add_column :event_plans, :deleted_at, :datetime
    add_index :event_plans, :deleted_at
  end
end
