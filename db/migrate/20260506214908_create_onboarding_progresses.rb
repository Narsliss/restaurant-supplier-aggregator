class CreateOnboardingProgresses < ActiveRecord::Migration[7.1]
  def change
    create_table :onboarding_progresses do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string   :role,            null: false                 # owner | manager | chef
      t.string   :current_step,    null: false, default: "welcome"
      t.jsonb    :completed_steps, null: false, default: []
      t.datetime :started_at,      null: false
      t.datetime :completed_at
      t.datetime :dismissed_at
      t.integer  :restart_count,   null: false, default: 0

      t.timestamps
    end
  end
end
