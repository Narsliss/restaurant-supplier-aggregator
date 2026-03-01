class CreateEventPlanMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :event_plan_messages do |t|
      t.references :event_plan, null: false, foreign_key: true
      t.string     :role, null: false
      t.text       :content, null: false
      t.jsonb      :structured_data, null: false, default: {}
      t.string     :status, null: false, default: "complete"
      t.timestamps
    end
  end
end
