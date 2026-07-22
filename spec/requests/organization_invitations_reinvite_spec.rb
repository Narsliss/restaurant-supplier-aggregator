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
