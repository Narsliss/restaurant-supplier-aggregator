require 'rails_helper'

RSpec.describe 'Access control', type: :request do
  describe 'salesperson sandbox (redirect_salesperson_to_crm)' do
    let(:salesperson) { create(:user, :salesperson) }

    before { sign_in salesperson }

    it 'redirects salespeople away from regular routes to /crm' do
      get root_path
      expect(response).to redirect_to(crm_root_path)
    end

    it 'redirects salespeople away from orders' do
      get orders_path
      expect(response).to redirect_to(crm_root_path)
    end

    it 'allows salespeople to reach /crm' do
      get crm_root_path
      expect(response).to have_http_status(:ok).or have_http_status(:redirect)
      # Should NOT redirect to crm_root_path (would be a self-redirect loop)
      expect(response.location).not_to eq(crm_root_path) if response.redirect?
    end
  end

  describe 'super_admin gate' do
    let(:regular_user) { create(:user, :fully_onboarded) }
    let(:super_admin) do
      User.where(role: 'super_admin').destroy_all
      create(:user, :super_admin)
    end

    it 'a regular user is bounced from /admin' do
      sign_in regular_user
      get '/admin'
      expect(response).not_to have_http_status(:ok)
    end

    it 'super admin can reach /admin' do
      sign_in super_admin
      get '/admin'
      expect(response).to have_http_status(:ok).or have_http_status(:redirect)
    end
  end

  describe 'subscription gate' do
    it 'redirects unsubscribed users to /subscriptions/new on gated controllers' do
      user = create(:user)
      org = create(:organization, complimentary: false)
      create(:membership, user: user, organization: org, role: 'owner')
      user.update!(current_organization: org)
      create(:location, user: user, organization: org)
      teammate = create(:user)
      create(:membership, user: teammate, organization: org, role: 'manager', active: true)

      sign_in user

      get orders_path
      expect(response).to redirect_to(new_subscription_path)
    end

    it 'allows complimentary users through' do
      sign_in create(:user, :fully_onboarded)
      get orders_path
      expect(response).to have_http_status(:ok)
    end

    it 'super_admins bypass the subscription check' do
      User.where(role: 'super_admin').destroy_all
      sign_in create(:user, :super_admin)
      get orders_path
      # Super admin has no org, so require_organization! redirects, not the subscription gate.
      # The point is: should NOT redirect to new_subscription_path.
      expect(response.location).not_to eq(new_subscription_url) if response.redirect?
    end
  end

  describe 'unauthenticated' do
    it 'redirects to login for any gated controller' do
      get orders_path
      expect(response).to redirect_to(new_user_session_path)

      get crm_root_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
