class CreateCrmTagsAndLeadTags < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_tags do |t|
      t.string :name, null: false
      t.string :color, default: "gray"
      t.timestamps
    end
    add_index :crm_tags, :name, unique: true

    create_table :crm_lead_tags do |t|
      t.references :lead, null: false, foreign_key: { to_table: :crm_leads }
      t.references :tag, null: false, foreign_key: { to_table: :crm_tags }
      t.timestamps
    end
    add_index :crm_lead_tags, [:lead_id, :tag_id], unique: true
  end
end
