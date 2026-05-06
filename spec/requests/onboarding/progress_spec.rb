require 'rails_helper'

RSpec.describe 'Onboarding::Progress', type: :request do
  describe 'unauthenticated' do
    it 'redirects to sign-in for GET /onboarding/progress' do
      get onboarding_progress_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'as a user without an eligible role (super_admin)' do
    let(:user) { create(:user, :super_admin) }
    before { sign_in user }

    it 'returns 204 No Content for show' do
      get onboarding_progress_path
      expect(response).to have_http_status(:no_content)
    end

    it 'returns 204 for advance' do
      post advance_onboarding_progress_path, params: { next_step: 'organization' }
      expect(response).to have_http_status(:no_content)
    end
  end

  describe 'as a salesperson' do
    let(:user) { create(:user, :salesperson) }

    it 'never reaches the wizard endpoints (redirected to CRM by app filter)' do
      sign_in user
      get onboarding_progress_path
      # Salesperson is bounced to CRM root by ApplicationController#redirect_salesperson_to_crm
      expect(response).to be_redirect
    end
  end

  describe 'as an owner' do
    let(:user) { create(:user, :with_organization) }
    before { sign_in user }

    describe 'GET /onboarding/progress' do
      it 'lazily creates a progress record on first call' do
        expect {
          get onboarding_progress_path
        }.to change(OnboardingProgress, :count).by(1)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body['role']).to eq('owner')
        expect(body['current_step']).to eq('welcome')
        expect(body['in_progress']).to be true
      end

      it 'reuses an existing record on subsequent calls' do
        get onboarding_progress_path
        expect {
          get onboarding_progress_path
        }.not_to change(OnboardingProgress, :count)
      end

      it 'includes computed completed steps in the payload' do
        get onboarding_progress_path
        body = JSON.parse(response.body)
        expect(body['completed_steps']).to include('organization')
      end
    end

    describe 'POST /onboarding/progress/advance' do
      it 'advances to the requested step' do
        post advance_onboarding_progress_path, params: { next_step: 'organization' }

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body['current_step']).to eq('organization')
      end

      it 'returns 422 when next_step is missing' do
        post advance_onboarding_progress_path, params: {}
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    describe 'POST /onboarding/progress/complete' do
      it 'marks the wizard completed' do
        post complete_onboarding_progress_path

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body['current_step']).to eq('done')
        expect(body['in_progress']).to be false
        expect(body['completed_at']).to be_present
      end
    end

    describe 'POST /onboarding/progress/skip' do
      it 'dismisses the wizard' do
        post skip_onboarding_progress_path

        body = JSON.parse(response.body)
        expect(body['dismissed_at']).to be_present
        expect(body['in_progress']).to be false
      end
    end

    describe 'POST /onboarding/progress/restart' do
      it 'resets a completed wizard back to welcome' do
        post complete_onboarding_progress_path
        post restart_onboarding_progress_path

        body = JSON.parse(response.body)
        expect(body['current_step']).to eq('welcome')
        expect(body['in_progress']).to be true
        expect(body['restart_count']).to eq(1)
      end
    end
  end

  describe 'cross-tenant isolation' do
    let(:owner_a) { create(:user, :with_organization) }
    let(:owner_b) { create(:user, :with_organization) }

    it 'does not leak progress between users' do
      sign_in owner_a
      post advance_onboarding_progress_path, params: { next_step: 'organization' }

      sign_out owner_a
      sign_in owner_b
      get onboarding_progress_path
      body = JSON.parse(response.body)
      expect(body['current_step']).to eq('welcome')
    end
  end

  describe 'works before the onboarding gate is satisfied (no org yet)' do
    let(:user) { create(:user) } # plain user, no membership, no org
    before { sign_in user }

    it 'still returns 200 with the owner flow' do
      get onboarding_progress_path
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['role']).to eq('owner')
    end

    it 'allows advancing the wizard before org creation' do
      post advance_onboarding_progress_path, params: { next_step: 'organization' }
      expect(response).to have_http_status(:ok)
    end
  end
end
