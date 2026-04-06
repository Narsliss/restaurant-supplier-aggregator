class CreateCrmActivities < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_activities do |t|
      t.references :lead, null: false, foreign_key: { to_table: :crm_leads }
      t.references :user, null: false, foreign_key: true

      t.string :activity_type, null: false
      t.string :subject
      t.text :body
      t.datetime :occurred_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.timestamps
    end

    add_index :crm_activities, [:lead_id, :occurred_at]
  end
end
