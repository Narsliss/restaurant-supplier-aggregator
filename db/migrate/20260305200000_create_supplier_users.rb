class CreateSupplierUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :supplier_users do |t|
      t.references :supplier, null: false, foreign_key: true

      ## Database authenticatable
      t.string :email, null: false
      t.string :encrypted_password, null: false, default: ""

      ## Profile
      t.string :first_name, null: false
      t.string :last_name, null: false
      t.string :role, null: false, default: "rep"
      t.string :phone
      t.boolean :active, null: false, default: true

      ## Recoverable
      t.string :reset_password_token
      t.datetime :reset_password_sent_at

      ## Rememberable
      t.datetime :remember_created_at

      ## Trackable
      t.integer :sign_in_count, default: 0, null: false
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string :current_sign_in_ip
      t.string :last_sign_in_ip

      ## Lockable
      t.integer :failed_attempts, default: 0, null: false
      t.string :unlock_token
      t.datetime :locked_at

      ## Invitation tracking
      t.string :invitation_token
      t.datetime :invitation_accepted_at

      t.timestamps
    end

    add_index :supplier_users, :email, unique: true
    add_index :supplier_users, :reset_password_token, unique: true
    add_index :supplier_users, :unlock_token, unique: true
    add_index :supplier_users, :invitation_token, unique: true
  end
end
