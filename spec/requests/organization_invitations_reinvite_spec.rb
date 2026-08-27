require "rails_helper"

# Regression: a stale (expired, never-accepted) invitation row used to block
# re-inviting the same email forever — while being invisible in the Pending
# Invitations UI ("Email has already been invited to this organization").
RSpec.describe "Re-inviting after a stale invitation", type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:organization) { owner.current_organization }
  let(:location) { create(:location, organization: organization) }

  before { sign_in owner }

  def create_invitation(expires_at:, accepted_at: nil, email: "returning.chef@example.com")
    invitation = organization.organization_invitations.new(
      email: email, role: "chef", location_id: location.id, invited_by: owner
    )
    invitation.save!
    invitation.update_columns(expires_at: expires_at, accepted_at: accepted_at)
    invitation
  end

  describe "model uniqueness" do
    it "still blocks a duplicate while an invitation is PENDING" do
      create_invitation(expires_at: 7.days.from_now)
      dup = organization.organization_invitations.new(
        email: "returning.chef@example.com", role: "chef", location_id: location.id, invited_by: owner
      )
      expect(dup).not_to be_valid
      expect(dup.errors[:email].join).to include("already been invited")
    end

    it "does not block when the previous invitation EXPIRED un-accepted" do
      create_invitation(expires_at: 2.days.ago)
      fresh = organization.organization_invitations.new(
        email: "returning.chef@example.com", role: "chef", location_id: location.id, invited_by: owner
      )
      expect(fresh).to be_valid
    end

    it "does not block when the previous invitation was accepted (ex-member re-invite)" do
      create_invitation(expires_at: 2.days.ago, accepted_at: 10.days.ago)
      fresh = organization.organization_invitations.new(
        email: "returning.chef@example.com", role: "chef", location_id: location.id, invited_by: owner
      )
      expect(fresh).to be_valid
    end
  end

  describe "POST /organization/invitations with a stale row present" do
    it "creates the new invitation and purges the expired row" do
      stale = create_invitation(expires_at: 2.days.ago)

      expect {
        post organization_invitations_path, params: {
          organization_invitation: { email: "returning.chef@example.com", role: "chef", location_id: location.id }
        }
      }.to change(organization.organization_invitations.pending, :count).by(1)

      expect(OrganizationInvitation.exists?(stale.id)).to be(false)
      expect(response).to redirect_to(organization_path(invited: "returning.chef@example.com"))
    end
  end

  # Regression: removing a chef and inviting the same email back used to fail
  # twice over — the create action raised RecordNotUnique against an
  # unconditional (organization_id, email) index that the accepted row still
  # occupied, and accepting the invite raised on a duplicate membership.
  describe "re-inviting a REMOVED member" do
    let(:chef) { create(:user, email: "returning.chef@example.com") }
    let(:other_location) { create(:location, organization: organization) }

    def invite_accept_and_remove!
      invitation = organization.organization_invitations.create!(
        email: chef.email, role: "chef", location_id: location.id, invited_by: owner
      )
      membership = invitation.accept!(chef)
      membership.deactivate!
      membership
    end

    it "creates a fresh invitation past the accepted row" do
      invite_accept_and_remove!

      expect {
        post organization_invitations_path, params: {
          organization_invitation: { email: chef.email, role: "chef", location_id: other_location.id }
        }
      }.to change(organization.organization_invitations.pending, :count).by(1)

      expect(response).to redirect_to(organization_path(invited: chef.email))
    end

    it "reactivates the existing membership on accept instead of duplicating it" do
      removed = invite_accept_and_remove!
      fresh = organization.organization_invitations.create!(
        email: chef.email, role: "chef", location_id: other_location.id, invited_by: owner
      )

      expect { fresh.accept!(chef) }
        .not_to change { organization.memberships.where(user: chef).count }

      expect(organization.member?(chef)).to be(true)
      expect(removed.reload).to be_active
      expect(removed.deactivated_at).to be_nil
      # The re-invite's restaurant replaces the old assignment.
      expect(removed.locations).to contain_exactly(other_location)
    end

    it "still rejects an email that is currently an ACTIVE member" do
      invitation = organization.organization_invitations.create!(
        email: chef.email, role: "chef", location_id: location.id, invited_by: owner
      )
      invitation.accept!(chef)

      post organization_invitations_path, params: {
        organization_invitation: { email: chef.email, role: "chef", location_id: location.id }
      }

      expect(response).to redirect_to(organization_path(error: "already_member"))
    end

    it "keeps a database guard against two OPEN invitations for one email" do
      organization.organization_invitations.create!(
        email: chef.email, role: "chef", location_id: location.id, invited_by: owner
      )
      duplicate = organization.organization_invitations.new(
        email: chef.email, role: "chef", location_id: location.id, invited_by: owner,
        token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "Team page visibility" do
    it "lists expired un-accepted invitations in the Expired section" do
      create_invitation(expires_at: 2.days.ago)

      get organization_path
      expect(response.body).to include("Expired Invitations")
      expect(response.body).to include("returning.chef@example.com")
      expect(response.body).to include("Re-invite")
    end

    it "does not list accepted invitations as expired" do
      create_invitation(expires_at: 2.days.ago, accepted_at: 10.days.ago)

      get organization_path
      expect(response.body).not_to include("Expired Invitations")
    end
  end
end
