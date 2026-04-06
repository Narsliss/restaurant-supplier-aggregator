class CreateCrmTasks < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_tasks do |t|
      t.references :lead, null: false, foreign_key: { to_table: :crm_leads }
      t.references :assigned_to, null: false, foreign_key: { to_table: :users }

      t.string :title, null: false
      t.text :description
      t.date :due_date, null: false
      t.datetime :completed_at
      t.string :priority, default: "normal"

      t.timestamps
    end

    add_index :crm_tasks, [:assigned_to_id, :due_date, :completed_at]
    add_index :crm_tasks, [:lead_id, :due_date]
  end
end
