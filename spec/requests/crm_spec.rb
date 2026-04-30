require 'rails_helper'

RSpec.describe 'CRM namespace', type: :request do
  let(:salesperson) { create(:user, :salesperson) }

  describe 'authentication gate' do
    it 'unauthenticated → sign-in' do
      get crm_root_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it 'a regular user is forbidden from /crm' do
      regular_user = create(:user, :fully_onboarded)
      sign_in regular_user
      get crm_root_path
      # Devise authenticate :user predicate failure returns 401/302 — not 200
      expect(response.status).not_to eq(200)
    end
  end

  describe 'GET /crm' do
    it 'returns 200 for salesperson' do
      sign_in salesperson
      get crm_root_path
      expect(response).to have_http_status(:ok)
    end

    it 'returns 200 for super_admin' do
      User.where(role: 'super_admin').destroy_all
      super_admin = create(:user, :super_admin)
      sign_in super_admin
      get crm_root_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /crm/leads' do
    it 'returns 200 for salesperson' do
      sign_in salesperson
      get '/crm/leads'
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /crm/leads' do
    it 'creates a lead owned by the salesperson' do
      sign_in salesperson

      expect {
        post '/crm/leads', params: {
          crm_lead: {
            restaurant_name: 'Test Bistro', contact_name: 'Chef A',
            pipeline_stage: 'lead'
          }
        }
      }.to change(Crm::Lead, :count).by(1)

      expect(Crm::Lead.last.salesperson).to eq(salesperson)
    end
  end

  describe 'PATCH /crm/leads/:id/move_stage' do
    let!(:lead) { create(:crm_lead, salesperson: salesperson) }

    it 'updates the pipeline_stage' do
      sign_in salesperson
      patch "/crm/leads/#{lead.id}/move_stage", params: { pipeline_stage: 'demo_scheduled' }
      expect(lead.reload.pipeline_stage).to eq('demo_scheduled')
    end
  end

  describe 'cross-salesperson visibility' do
    # Note: leads are not scoped by salesperson in Crm::LeadsController#show —
    # this is intentional (the team shares pipeline visibility). If you want
    # per-salesperson lead isolation, scope @lead in the controller.
    it 'all salespeople can view all leads (shared pipeline)' do
      other_sp = create(:user, :salesperson)
      foreign_lead = create(:crm_lead, salesperson: other_sp)

      sign_in salesperson
      get "/crm/leads/#{foreign_lead.id}"
      expect(response).to have_http_status(:ok)
    end
  end
end
