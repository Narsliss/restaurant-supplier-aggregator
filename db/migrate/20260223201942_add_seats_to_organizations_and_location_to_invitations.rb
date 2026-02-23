class AddSeatsToOrganizationsAndLocationToInvitations < ActiveRecord::Migration[7.1]
  def change
    # Seat cap for organizations
    add_column :organizations, :max_seats, :integer, default: 5, null: false
    add_column :organizations, :additional_seats, :integer, default: 0, null: false

    # Chef invitation → single restaurant assignment
    add_reference :organization_invitations, :location, foreign_key: true, null: true

    # Manager invitation → multiple restaurant assignments
    add_column :organization_invitations, :location_ids, :jsonb, default: []
  end
end
