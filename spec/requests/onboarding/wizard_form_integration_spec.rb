require 'rails_helper'

# Coverage for the form-based pieces of the onboarding wizard:
#   - The ONBOARDING_WIZARD env flag (kill switch)
#   - Owner-vs-chef eligibility differences during their respective hard-gates
#   - The from_wizard=1 marker-frame responses on the org / location /
#     invitation controllers
#   - The wizard-aware new action on Organizations::InvitationsController
RSpec.describe 'Onboarding wizard — form integration', type: :request do
  describe 'ONBOARDING_WIZARD feature flag' do
    let(:user) { create(:user, :fully_onboarded) }
    before { sign_in user }

    around do |ex|
      original = ENV['ONBOARDING_WIZARD']
      ex.run
    ensure
      if original.nil?
        ENV.delete('ONBOARDING_WIZARD')
      else
        ENV['ONBOARDING_WIZARD'] = original
      end
    end

    it 'renders the wizard partial when ONBOARDING_WIZARD is unset (default)' do
      ENV.delete('ONBOARDING_WIZARD')
      get root_path
      expect(response.body).to include('data-controller="onboarding-wizard"')
    end

    it 'renders the wizard partial when ONBOARDING_WIZARD=true' do
      ENV['ONBOARDING_WIZARD'] = 'true'
      get root_path
      expect(response.body).to include('data-controller="onboarding-wizard"')
    end

    it 'suppresses the wizard partial when ONBOARDING_WIZARD=false' do
      ENV['ONBOARDING_WIZARD'] = 'false'
      get root_path
      expect(response.body).not_to include('data-controller="onboarding-wizard"')
    end

    it 'leaves the wizard JSON API endpoints reachable when the flag is false' do
      # The flag only suppresses rendering of the partial, not the API.
      # That way "Restart Tour" can still flip state if needed.
      ENV['ONBOARDING_WIZARD'] = 'false'
      get onboarding_progress_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'eligibility during legacy hard-gates' do
    context 'owner with no organization yet' do
      let(:user) { create(:user) } # plain user — no membership, no org
      before { sign_in user }

      it 'suppresses the wizard so the legacy fullscreen owner setup runs' do
        get root_path
        expect(response.body).not_to include('data-controller="onboarding-wizard"')
      end
    end

    context 'chef with no supplier credentials' do
      let(:user) do
        u = create(:user)
        org = create(:organization)
        create(:location, user: u, organization: org)
        create(:membership, user: u, organization: org, role: 'chef', active: true)
        u.update!(current_organization: org)
        u
      end
      before { sign_in user }

      it 'falls through to the regular dashboard with the wizard mounted' do
        get root_path
        expect(response.body).to include('data-controller="onboarding-wizard"')
        expect(response.body).to include('data-onboarding-wizard-role-value="chef"')
      end

      it 'does NOT render the legacy chef-onboarding fullscreen' do
        get root_path
        # Legacy fullscreen rendered "Connect a supplier to unlock EnPlace Pro."
        # in dashboard/index.html.erb when @chef_onboarding_steps was set.
        expect(response.body).not_to match(/Connect a supplier to unlock/i)
      end
    end
  end

  describe 'OrganizationsController#update with from_wizard=1' do
    let(:user) { create(:user, :fully_onboarded) }
    before { sign_in user }

    it 'returns the saved-marker frame on success' do
      org = user.current_organization
      patch organization_path,
            params: { organization: { name: 'Renamed Org' }, from_wizard: '1' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-frame id="onboarding-step-form">')
      expect(response.body).to include('data-onboarding-form-saved="true"')
      expect(org.reload.name).to eq('Renamed Org')
    end

    it 'still redirects normally when from_wizard is absent' do
      patch organization_path, params: { organization: { name: 'Other Name' } }
      expect(response).to be_redirect
    end
  end

  describe 'LocationsController#create with from_wizard=1' do
    let(:user) { create(:user, :fully_onboarded) }
    before { sign_in user }

    it 'creates the location and returns the saved-marker frame' do
      expect {
        post locations_path,
             params: {
               location: { name: 'Wizard Branch', address: '123 Test', city: 'NYC', state: 'NY', zip_code: '10001' },
               from_wizard: '1',
             }
      }.to change(Location, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-onboarding-form-saved="true"')
    end

    it 'redirects normally without from_wizard' do
      post locations_path,
           params: {
             location: { name: 'Standalone Branch', address: '456 Test', city: 'NYC', state: 'NY', zip_code: '10002' },
           }
      expect(response).to be_redirect
    end

    it 'still re-renders the form with errors on invalid submission (wizard mode)' do
      post locations_path, params: { location: { name: '' }, from_wizard: '1' }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'Organizations::InvitationsController' do
    let(:user) { create(:user, :fully_onboarded) }
    before { sign_in user }

    describe 'GET /organization/invitations/new' do
      it 'renders the form (200) without from_wizard' do
        get new_organization_invitation_path
        expect(response).to have_http_status(:ok)
      end

      it 'wraps the form in the turbo-frame when from_wizard=1' do
        get new_organization_invitation_path(from_wizard: 1)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('<turbo-frame id="onboarding-step-form">')
      end
    end

    describe 'POST /organization/invitations with from_wizard=1' do
      it 'creates the invitation and returns the saved-marker frame' do
        location = user.current_organization.locations.first
        expect {
          post organization_invitations_path,
               params: {
                 organization_invitation: {
                   email: 'wizard-invitee@example.com',
                   role: 'chef',
                   location_id: location.id,
                 },
                 from_wizard: '1',
               }
        }.to change(OrganizationInvitation, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-onboarding-form-saved="true"')
      end

      it 're-renders the form with errors on validation failure (wizard mode)' do
        post organization_invitations_path,
             params: {
               organization_invitation: { email: '', role: '' },
               from_wizard: '1',
             }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include('<turbo-frame id="onboarding-step-form">')
      end
    end

    describe 'POST /organization/invitations without from_wizard' do
      it 'redirects (legacy behavior preserved)' do
        location = user.current_organization.locations.first
        post organization_invitations_path,
             params: {
               organization_invitation: {
                 email: 'standalone-invitee@example.com',
                 role: 'chef',
                 location_id: location.id,
               },
             }
        expect(response).to be_redirect
      end
    end
  end

  describe 'onboarding_wizard_form_marker_html helper' do
    let(:controller) { ApplicationController.new }

    it 'wraps the message in a turbo-frame with the saved marker' do
      html = controller.send(:onboarding_wizard_form_marker_html, 'Saved')
      expect(html).to include('<turbo-frame id="onboarding-step-form">')
      expect(html).to include('data-onboarding-form-saved="true"')
      expect(html).to include('✓ Saved')
    end

    it 'escapes HTML in the message to prevent XSS' do
      html = controller.send(:onboarding_wizard_form_marker_html, '<script>alert(1)</script>')
      expect(html).not_to include('<script>')
      expect(html).to include('&lt;script&gt;')
    end

    it 'returns html_safe content (so render html: skips re-escaping)' do
      html = controller.send(:onboarding_wizard_form_marker_html, 'Done')
      expect(html).to be_html_safe
    end
  end
end
