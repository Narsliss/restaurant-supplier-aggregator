class BackfillOrganizationOnLocations < ActiveRecord::Migration[7.1]
  def up
    # For each location missing organization_id, set it from the user's current_organization
    execute <<~SQL
      UPDATE locations
      SET organization_id = users.current_organization_id
      FROM users
      WHERE locations.user_id = users.id
        AND locations.organization_id IS NULL
        AND users.current_organization_id IS NOT NULL
    SQL

    # Edge case: if user has no org, create a personal org
    # (handled in Ruby for complex logic)
    Location.where(organization_id: nil).find_each do |location|
      user = User.find_by(id: location.user_id)
      next unless user

      if user.current_organization.present?
        location.update_column(:organization_id, user.current_organization_id)
      elsif user.organizations.any?
        location.update_column(:organization_id, user.organizations.first.id)
      else
        # Create a personal org for this orphaned user
        org = Organization.create!(
          name: "#{user.email.split('@').first}'s Organization",
          slug: "personal-#{user.id}"
        )
        Membership.create!(user: user, organization: org, role: 'owner', active: true)
        user.update_column(:current_organization_id, org.id)
        location.update_column(:organization_id, org.id)
      end
    end
  end

  def down
    # No-op: we don't want to null out organization_ids on rollback
  end
end
