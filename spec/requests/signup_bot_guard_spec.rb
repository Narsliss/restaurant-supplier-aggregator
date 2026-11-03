require "rails_helper"

# The sign-up form's honeypot + minimum-fill-time checks (SignupBotGuard).
# Invited chefs use this same form, so the invite path is covered explicitly.
RSpec.describe "Sign-up bot guard", type: :request do
  let(:user_params) do
    {
      first_name: "Real", last_name: "Chef", email: "real.chef@example.com",
      password: "Password1!", password_confirmation: "Password1!"
    }
  end

  def human_token
    SignupBotGuard.timestamp_token(now: 20.seconds.ago)
  end

  def token_from(body)
    body[/name="ep_ts"[^>]*value="([^"]+)"/, 1] || body[/value="([^"]+)"[^>]*name="ep_ts"/, 1]
  end

  describe "GET /users/sign_up" do
    it "renders the timestamp and a hidden, non-autofill honeypot" do
      get new_user_registration_path

      expect(response).to have_http_status(:ok)
      expect(token_from(response.body)).to be_present
      honeypot = response.body[/<div class="sr-only" aria-hidden="true">.*?<\/div>/m]
      expect(honeypot).to include('name="ep_hp"', 'tabindex="-1"', 'autocomplete="off"', "data-1p-ignore")
    end
  end

  describe "POST /users" do
    it "creates the account for a human-paced submit" do
      expect {
        post user_registration_path, params: { user: user_params, ep_ts: human_token, ep_hp: "" }
      }.to change(User, :count).by(1)
      expect(response).to redirect_to(root_path)
    end

    it "rejects the Nov 3 bot's exact name even when it passes the bot checks" do
      bot_name = '* * * <a href="https://myxa.cc/">SCAM SERVICE 24/7</a> * * * hs=48508029c103811db09d3bd6f5688b5a* xxx* htv04d'

      expect {
        post user_registration_path, params: { user: user_params.merge(first_name: bot_name), ep_ts: human_token, ep_hp: "" }
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(CGI.escapeHTML("First name can't contain links or the < > characters"))
    end

    it "creates no account when the honeypot is filled, and logs why" do
      allow(Rails.logger).to receive(:warn).and_call_original

      expect {
        post user_registration_path, params: { user: user_params, ep_ts: human_token, ep_hp: "SCAM SERVICE 24/7" }
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Please check your details and submit again.")
      expect(Rails.logger).to have_received(:warn).with(a_string_including("[SignupBotGuard] blocked reason=honeypot", "email_domain=example.com"))
    end

    it "creates no account when POSTed without ever loading the form" do
      expect {
        post user_registration_path, params: { user: user_params }
      }.not_to change(User, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "lets a person caught by the timer through on the next submit" do
      post user_registration_path, params: { user: user_params, ep_ts: SignupBotGuard.timestamp_token, ep_hp: "" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(User.find_by(email: user_params[:email])).to be_nil
      expect(response.body).to include('value="real.chef@example.com"') # their details are kept
      fresh_token = token_from(response.body)
      expect(fresh_token).to be_present

      travel 10.seconds do
        expect {
          post user_registration_path, params: { user: user_params, ep_ts: fresh_token, ep_hp: "" }
        }.to change(User, :count).by(1)
      end
    end
  end

  describe "invited chef signing up" do
    let(:owner) { create(:user, :fully_onboarded) }
    let(:organization) { owner.current_organization }
    let(:location) { create(:location, organization: organization) }
    let!(:invitation) do
      organization.organization_invitations.create!(
        email: "invited.chef@example.com", role: "chef", location_id: location.id, invited_by: owner
      )
    end
    let(:invited_params) { user_params.merge(email: "invited.chef@example.com") }

    it "joins the organization through the real form flow" do
      get accept_invitation_path(token: invitation.token)
      expect(response).to redirect_to(new_user_registration_path)

      get new_user_registration_path
      token = token_from(response.body)
      expect(token).to be_present

      travel 10.seconds do
        expect {
          post user_registration_path, params: { user: invited_params, ep_ts: token, ep_hp: "" }
        }.to change(User, :count).by(1)
      end

      expect(invitation.reload).to be_accepted
      expect(organization.member?(User.find_by(email: "invited.chef@example.com"))).to be(true)
    end

    it "keeps the invitation form (locked email, Join button) when the timer trips" do
      get accept_invitation_path(token: invitation.token)

      post user_registration_path, params: { user: invited_params, ep_ts: SignupBotGuard.timestamp_token, ep_hp: "" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Join #{organization.name}")
      expect(response.body).to match(/value="invited\.chef@example\.com"[^>]*readonly|readonly[^>]*value="invited\.chef@example\.com"/)
      expect(invitation.reload).not_to be_accepted
    end
  end
end
