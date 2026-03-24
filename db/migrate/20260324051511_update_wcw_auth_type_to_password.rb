class UpdateWcwAuthTypeToPassword < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      UPDATE suppliers
      SET auth_type = 'password', password_required = true
      WHERE code = 'whatchefswant'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE suppliers
      SET auth_type = 'welcome_url', password_required = false
      WHERE code = 'whatchefswant'
    SQL
  end
end
