class BackfillMembershipLocationsForExistingMembers < ActiveRecord::Migration[7.1]
  def up
    # For existing non-owner members, assign them to ALL locations in their org
    # (owner can reassign later via the UI)
    execute <<~SQL
      INSERT INTO membership_locations (membership_id, location_id, created_at, updated_at)
      SELECT m.id, l.id, NOW(), NOW()
      FROM memberships m
      JOIN locations l ON l.organization_id = m.organization_id
      WHERE m.role != 'owner'
        AND m.active = true
        AND NOT EXISTS (
          SELECT 1 FROM membership_locations ml
          WHERE ml.membership_id = m.id AND ml.location_id = l.id
        )
    SQL
  end

  def down
    # Remove all auto-assigned membership_locations
    execute "DELETE FROM membership_locations"
  end
end
