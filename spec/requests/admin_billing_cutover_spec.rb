require 'rails_helper'

RSpec.describe 'Admin Stripe test-mode cleanup', type: :request do
  let(:super_admin) { create(:user, :super_admin) }
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let!(:test_sub) { create(:subscription, user: owner, organization_id: org.id, stripe_subscription_id: 'sub_test_era') }

  def resource_missing
    ::Stripe::InvalidRequestError.new('No such object', 'id', code: 'resource_missing')
  end

  # Admin routes only exist for super admins (authenticate block in routes.rb).
  it 'is super-admin only' do
    allow(::Stripe).to receive(:api_key).and_return('sk_live_example')
    sign_in owner

    get admin_billing_cutover_path
    expect(response).to have_http_status(:not_found)

    post admin_billing_cutover_path
    expect(test_sub.reload.status).to eq('active')
  end

  context 'on the test key' do
    before do
      allow(::Stripe).to receive(:api_key).and_return('sk_test_example')
      sign_in super_admin
    end

    it 'says the key is still test and offers no button' do
      get admin_billing_cutover_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-stripe-mode="test"')
      expect(response.body).not_to include('Clean up test-mode billing')
    end

    it 'refuses to run' do
      post admin_billing_cutover_path
      expect(response).to redirect_to(admin_billing_cutover_path)
      expect(flash[:alert]).to include('still on the test key')
      expect(test_sub.reload.status).to eq('active')
    end
  end

  context 'on the live key' do
    before do
      allow(::Stripe).to receive(:api_key).and_return('sk_live_example')
      allow(::Stripe::Subscription).to receive(:retrieve).and_raise(resource_missing)
      allow(::Stripe::Customer).to receive(:retrieve).and_raise(resource_missing)
      org.update!(stripe_customer_id: 'cus_test_era')
      sign_in super_admin
    end

    it 'previews what will change' do
      get admin_billing_cutover_path
      expect(response.body).to include('data-stripe-mode="live"')
      expect(response.body).to include(org.name)
      expect(response.body).to include('Clean up test-mode billing')
    end

    it 'retires the test subscription and shows it as done' do
      post admin_billing_cutover_path
      expect(response).to redirect_to(admin_billing_cutover_path)
      expect(test_sub.reload.status).to eq('canceled')

      follow_redirect!
      expect(response.body).to include('data-cutover-clean')
      expect(response.body).to include('data-cutover-retired')
    end
  end
end
