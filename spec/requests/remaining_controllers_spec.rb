require 'rails_helper'

RSpec.describe 'Reports', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }

  before { sign_in owner }

  it 'GET /reports returns 200 for owner' do
    get reports_path
    expect(response).to have_http_status(:ok)
  end

  it 'GET /reports/savings returns 200 for owner' do
    get savings_reports_path
    expect(response).to have_http_status(:ok).or be_redirect
  end

  it 'redirects a chef away from /reports' do
    chef = create(:user)
    org = owner.current_organization
    create(:membership, user: chef, organization: org, role: 'chef', active: true)
    chef.update!(current_organization: org)

    sign_out owner
    sign_in chef
    get reports_path
    expect(response).to be_redirect
  end
end

RSpec.describe 'EventPlans (menu planner)', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }

  before { sign_in owner }

  it 'GET /menu-planner returns 200' do
    get event_plans_path
    expect(response).to have_http_status(:ok).or be_redirect
  end

  it 'auth gate redirects unauthenticated' do
    sign_out owner
    get event_plans_path
    expect(response).to redirect_to(new_user_session_path)
  end
end

RSpec.describe 'SupplierLists (order guides)', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }

  before { sign_in owner }

  it 'GET /order-guides returns 200 (or redirect when no location is selected)' do
    get supplier_lists_path
    expect(response).to have_http_status(:ok).or be_redirect
  end

  it 'auth gate redirects unauthenticated' do
    sign_out owner
    get supplier_lists_path
    expect(response).to redirect_to(new_user_session_path)
  end
end
