class CreateCrmLeads < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_leads do |t|
      t.references :salesperson, null: false, foreign_key: { to_table: :users }
      t.references :organization, foreign_key: true

      t.string :restaurant_name, null: false
      t.string :contact_name, null: false
      t.string :contact_role
      t.string :phone
      t.string :email
      t.string :city
      t.string :state
      t.string :estimated_volume
      t.text :pain_point
      t.text :current_suppliers
      t.integer :deal_value_cents, default: 0
      t.string :pipeline_stage, null: false, default: "lead"
      t.text :next_action
      t.text :lost_reason
      t.datetime :closed_at

      t.timestamps
    end

    add_index :crm_leads, :pipeline_stage
    add_index :crm_leads, [:salesperson_id, :pipeline_stage]
  end
end
