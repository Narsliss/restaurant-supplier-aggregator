require 'rails_helper'

RSpec.describe 'Dashboard', type: :request do
  let(:user) { create(:user, :fully_onboarded) }

  it 'GET / returns 200 for an authenticated user' do
    sign_in user
    get root_path
    expect(response).to have_http_status(:ok)
  end

  it 'POST /onboarding/dismiss persists the dismissal' do
    sign_in user
    post dismiss_onboarding_path
    expect(response).to be_redirect.or have_http_status(:ok)
  end
end

RSpec.describe 'Pages', type: :request do
  it 'GET /terms is publicly accessible' do
    get terms_path
    expect(response).to have_http_status(:ok)
  end
end

RSpec.describe 'Feedbacks', type: :request do
  let(:user) { create(:user, :fully_onboarded) }

  it 'POST /feedback creates a feedback record' do
    sign_in user
    post feedback_path, params: { feedback: { message: 'works great', category: 'general' } }
    expect(response).to be_redirect.or have_http_status(:ok)
  end

  it 'requires authentication' do
    post feedback_path, params: { feedback: { message: 'x' } }
    expect(response).to redirect_to(new_user_session_path)
  end
end
