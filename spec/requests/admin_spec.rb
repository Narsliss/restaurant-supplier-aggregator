require 'rails_helper'

RSpec.describe 'Admin namespace', type: :request do
  let(:super_admin) do
    User.where(role: 'super_admin').destroy_all
    create(:user, :super_admin)
  end
  let(:regular_user) { create(:user, :fully_onboarded) }
  let(:target_org) do
    org = create(:organization)
    create(:membership, user: create(:user), organization: org, role: 'owner')
    org
  end

  describe 'authentication gate' do
    it 'redirects regular users away from /admin' do
      sign_in regular_user
      get '/admin'
      expect(response).not_to have_http_status(:ok)
    end

    it 'redirects unauthenticated users to sign in' do
      get '/admin'
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'GET /admin (super_admin)' do
    it 'renders the dashboard' do
      sign_in super_admin
      get '/admin'
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /admin/users' do
    it 'returns 200' do
      sign_in super_admin
      get '/admin/users', headers: { 'HTTP_HOST' => 'www.example.com' }
      # First request may be 301 → trailing-slash normalization, follow if so
      follow_redirect! if response.status == 301
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /admin/organizations' do
    it 'returns 200' do
      sign_in super_admin
      get '/admin/organizations'
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /admin/organizations/:id/suspend' do
    it 'sets suspended_at on the organization' do
      sign_in super_admin
      post "/admin/organizations/#{target_org.id}/suspend"
      expect(target_org.reload.suspended_at).to be_present
    end
  end

  describe 'POST /admin/organizations/:id/reactivate' do
    it 'clears suspended_at' do
      target_org.update!(suspended_at: 1.day.ago)
      sign_in super_admin
      post "/admin/organizations/#{target_org.id}/reactivate"
      expect(target_org.reload.suspended_at).to be_nil
    end
  end

  describe 'POST /admin/organizations/:id/grant_complimentary' do
    it 'flips complimentary on' do
      sign_in super_admin
      post "/admin/organizations/#{target_org.id}/grant_complimentary",
           params: { reason: 'beta tester' }
      expect(target_org.reload.complimentary).to be true
      expect(target_org.complimentary_reason).to eq('beta tester')
      expect(target_org.complimentary_granted_by_id).to eq(super_admin.id)
    end
  end

  describe 'POST /admin/organizations/:id/revoke_complimentary' do
    before do
      target_org.update!(complimentary: true, complimentary_granted_at: Time.current)
    end

    it 'flips complimentary off' do
      sign_in super_admin
      post "/admin/organizations/#{target_org.id}/revoke_complimentary"
      expect(target_org.reload.complimentary).to be false
    end
  end

  describe 'POST /admin/users/:id/impersonate' do
    let(:victim) { regular_user }

    it 'redirects super_admin into impersonation context' do
      sign_in super_admin
      post "/admin/users/#{victim.id}/impersonate"
      expect(response).to be_redirect
    end
  end

  describe 'regular user cannot trigger admin actions' do
    it 'POST suspend is blocked for non-super_admin' do
      sign_in regular_user
      expect {
        post "/admin/organizations/#{target_org.id}/suspend"
      }.not_to change { target_org.reload.suspended_at }
    end
  end
end
