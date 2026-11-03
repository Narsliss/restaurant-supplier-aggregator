require "rails_helper"

# Unpaid orgs can invite during onboarding (before the card), so invite emails
# are capped by InviteSendLimit. Regression for Nov 3 2026: cancel-and-reinvite
# sent 20 emails to 20 people from an org with no payment.
RSpec.describe "Invite email cap for unpaid organizations", type: :request do
  include ActiveJob::TestHelper

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  let(:limit) { InviteSendLimit::LIMIT }

  def invite_mails
    enqueued_jobs.count { |j| j["job_class"].to_s.include?("MailDeliveryJob") && j["arguments"].first == "OrganizationInvitationMailer" }
  end

  def invite(email, wizard: false)
    path = wizard ? organization_invitations_path(from_wizard: 1) : organization_invitations_path
    post path, params: { organization_invitation: { email: email, role: "chef", location_id: location.id } }
  end

  context "unpaid org (no card)" do
    let(:owner) { create(:user, :with_organization) }
    let(:org) { owner.current_organization }
    let(:location) { create(:location, organization: org) }

    before { sign_in owner }

    it "can still invite its first teammate (onboarding works)" do
      invite("first.chef@example.com")
      expect(response).to redirect_to(organization_path(invited: "first.chef@example.com"))
      expect(invite_mails).to eq(1)
    end

    it "stops cancel-and-reinvite at the cap, without creating the blocked invitation" do
      (limit + 5).times do |i|
        invite("victim#{i}@example.org")
        inv = org.organization_invitations.find_by(email: "victim#{i}@example.org")
        delete organization_invitation_path(inv) if inv
      end

      expect(invite_mails).to eq(limit)
      expect(OrganizationInvitation.where(organization: org)).to be_empty # all sent ones canceled, blocked ones never saved

      invite("one.more@example.org")
      expect(response).to redirect_to(organization_path(error: InviteSendLimit::MESSAGE))
      expect(org.organization_invitations.find_by(email: "one.more@example.org")).to be_nil
    end

    it "shows the cap message inside the onboarding wizard form" do
      limit.times { InviteSendLimit.record!(org) }

      invite("wizard.chef@example.com", wizard: true)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(CGI.escapeHTML(InviteSendLimit::MESSAGE))
      expect(invite_mails).to eq(0)
    end

    it "counts resends toward the cap and blocks them at the cap" do
      invite("resend.me@example.com")
      inv = org.organization_invitations.last

      (limit - 1).times { post resend_organization_invitation_path(inv) }
      expect(invite_mails).to eq(limit)

      post resend_organization_invitation_path(inv)
      expect(response).to redirect_to(organization_path(error: InviteSendLimit::MESSAGE))
      expect(invite_mails).to eq(limit)
    end
  end

  context "paid / complimentary org" do
    let(:owner) { create(:user, :fully_onboarded) }
    let(:org) { owner.current_organization }
    let(:location) { create(:location, organization: org) }

    before { sign_in owner }

    it "is never capped" do
      (limit + 5).times { |i| invite("team#{i}@example.com") }
      expect(invite_mails).to eq(limit + 5)
      expect(InviteSendLimit.sent(org)).to eq(0)
    end
  end

  # Regression: resend! wrote invitation_sent_at, a column that never existed,
  # so every Resend click raised UnknownAttributeError (Feb -> Nov 2026).
  describe "Resend button" do
    let(:owner) { create(:user, :fully_onboarded) }
    let(:org) { owner.current_organization }
    let(:location) { create(:location, organization: org) }

    before { sign_in owner }

    it "resends the email and extends the expiry" do
      invite("forgot.it@example.com")
      inv = org.organization_invitations.last
      inv.update_columns(expires_at: 1.day.from_now)

      expect {
        post resend_organization_invitation_path(inv)
      }.to change { invite_mails }.by(1)

      expect(response).to redirect_to(organization_path(resent: "forgot.it@example.com"))
      expect(inv.reload.expires_at).to be > 6.days.from_now
    end
  end
end
