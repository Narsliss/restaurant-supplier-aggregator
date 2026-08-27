class ScopeOrganizationInvitationUniquenessToOpenInvites < ActiveRecord::Migration[7.1]
  # The unconditional unique index on (organization_id, email) outlived the
  # model rule it was meant to back: only an OPEN (un-accepted) invitation may
  # block a duplicate. An accepted row — left behind by a member who was later
  # removed — made that email permanently un-invitable, raising
  # ActiveRecord::RecordNotUnique out of the create action.
  def up
    remove_index :organization_invitations,
                 column: %i[organization_id email],
                 name: "index_organization_invitations_on_organization_id_and_email"

    add_index :organization_invitations, %i[organization_id email],
              unique: true,
              where: "accepted_at IS NULL",
              name: "index_org_invitations_on_org_and_email_open"
  end

  def down
    remove_index :organization_invitations, name: "index_org_invitations_on_org_and_email_open"

    add_index :organization_invitations, %i[organization_id email],
              unique: true,
              name: "index_organization_invitations_on_organization_id_and_email"
  end
end
