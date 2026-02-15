# frozen_string_literal: true

# This migration enforces a single super_admin in the system
class AddSingleSuperAdminConstraint < ActiveRecord::Migration[7.1]
  def up
    # Add a partial unique index to ensure only one super_admin exists
    add_index :users, :role,
              unique: true,
              where: "role = 'super_admin'",
              name: 'index_users_on_super_admin_role'
  end

  def down
    remove_index :users, name: 'index_users_on_super_admin_role'
  end
end
