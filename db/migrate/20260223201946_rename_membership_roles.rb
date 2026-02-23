class RenameMembershipRoles < ActiveRecord::Migration[7.1]
  def up
    # admin → manager, member → chef
    execute "UPDATE memberships SET role = 'manager' WHERE role = 'admin'"
    execute "UPDATE memberships SET role = 'chef' WHERE role = 'member'"
    execute "UPDATE organization_invitations SET role = 'manager' WHERE role = 'admin'"
    execute "UPDATE organization_invitations SET role = 'chef' WHERE role = 'member'"
  end

  def down
    execute "UPDATE memberships SET role = 'admin' WHERE role = 'manager'"
    execute "UPDATE memberships SET role = 'member' WHERE role = 'chef'"
    execute "UPDATE organization_invitations SET role = 'admin' WHERE role = 'manager'"
    execute "UPDATE organization_invitations SET role = 'member' WHERE role = 'chef'"
  end
end
