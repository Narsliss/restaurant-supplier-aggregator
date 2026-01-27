class CreateSupplierCredentials < ActiveRecord::Migration[7.1]
  def change
    create_table :supplier_credentials do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :location, foreign_key: { on_delete: :cascade }
      t.references :supplier, null: false, foreign_key: { on_delete: :cascade }

      # Encrypted credentials
      t.text :encrypted_username, null: false
      t.string :encrypted_username_iv, null: false
      t.text :encrypted_password, null: false
      t.string :encrypted_password_iv, null: false
      t.text :encrypted_session_data
      t.string :encrypted_session_data_iv

      # Status tracking
      t.string :status, default: "pending"
      t.datetime :last_login_at
      t.text :last_error

      # 2FA support
      t.boolean :two_fa_enabled, default: false
      t.string :two_fa_type
      t.text :trusted_device_token
      t.datetime :trusted_device_expires_at

      # Account status
      t.boolean :account_on_hold, default: false
      t.string :hold_reason

      t.timestamps
    end

    add_index :supplier_credentials, [:user_id, :location_id, :supplier_id], 
              unique: true, name: "idx_supplier_creds_unique"
    add_index :supplier_credentials, :status
  end
end
