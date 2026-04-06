class CreateCrmOnboardings < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_onboardings do |t|
      t.references :lead, null: false, foreign_key: { to_table: :crm_leads }, index: { unique: true }
      t.references :organization, null: false, foreign_key: true, index: { unique: true }

      t.string :stage, null: false, default: "signed_up"
      t.string :health_score, default: "green"
      t.datetime :signed_up_at
      t.datetime :account_setup_at
      t.datetime :suppliers_connected_at
      t.datetime :first_order_at
      t.datetime :check_in_14_at
      t.datetime :check_in_30_at
      t.datetime :check_in_60_at
      t.datetime :check_in_90_at
      t.text :notes

      t.timestamps
    end
  end
end
