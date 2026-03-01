class CreateEventPlans < ActiveRecord::Migration[7.1]
  def change
    create_table :event_plans do |t|
      t.references :user, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.string     :title
      t.string     :status, null: false, default: "drafting"
      t.jsonb      :event_details, null: false, default: {}
      t.jsonb      :current_menu, null: false, default: {}
      t.timestamps
    end

    add_index :event_plans, [:organization_id, :user_id]
    add_index :event_plans, :status
  end
end
