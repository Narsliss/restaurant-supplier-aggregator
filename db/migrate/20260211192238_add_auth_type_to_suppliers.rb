class AddAuthTypeToSuppliers < ActiveRecord::Migration[7.1]
  def up
    add_column :suppliers, :auth_type, :string, default: "password", null: false

    # Migrate existing data: password_required=true → "password", false → "two_fa"
    execute <<~SQL
      UPDATE suppliers SET auth_type = CASE
        WHEN password_required = 0 THEN 'two_fa'
        ELSE 'password'
      END
    SQL

    # Set What Chefs Want to welcome_url auth type
    execute "UPDATE suppliers SET auth_type = 'welcome_url' WHERE code = 'whatchefswant'"
  end

  def down
    remove_column :suppliers, :auth_type
  end
end
