class CreateSupplier2faRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :supplier_2fa_requests do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :supplier_credential, null: false, foreign_key: { on_delete: :cascade }
      t.string :session_token, null: false
      t.string :request_type, null: false  # 'login', 'checkout', 'price_refresh'
      t.string :two_fa_type               # 'sms', 'totp', 'email', 'unknown'
      t.text :prompt_message              # Message shown by supplier
      t.string :status, default: "pending" # 'pending', 'submitted', 'verified', 'failed', 'expired', 'cancelled'
      t.string :code_submitted            # The code user entered
      t.integer :attempts, default: 0
      t.datetime :expires_at, null: false
      t.datetime :verified_at

      t.timestamps
    end

    add_index :supplier_2fa_requests, :session_token, unique: true
    add_index :supplier_2fa_requests, :status
    add_index :supplier_2fa_requests, [:user_id, :status]
  end
end
