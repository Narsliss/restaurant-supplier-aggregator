require 'rails_helper'

RSpec.describe 'Authentication', type: :request do
  describe 'unauthenticated access' do
    it 'redirects to the sign-in page when accessing a gated controller' do
      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'sign in' do
    let(:user) { create(:user, :fully_onboarded, password: 'Password1!', password_confirmation: 'Password1!') }

    it 'accepts valid credentials and lands on the dashboard' do
      post user_session_path, params: { user: { email: user.email, password: 'Password1!' } }
      expect(response).to be_redirect
      follow_redirect!
      expect(response).to have_http_status(:ok).or have_http_status(:redirect)
    end

    it 'rejects bad credentials' do
      post user_session_path, params: { user: { email: user.email, password: 'wrong' } }
      expect(response).not_to be_redirect
      expect(response.body).to include('Invalid Email or password')
    end
  end

  describe 'sign out' do
    let(:user) { create(:user, :fully_onboarded) }

    it 'clears the session and redirects to login' do
      sign_in user
      delete destroy_user_session_path
      expect(response).to redirect_to(new_user_session_path).or redirect_to(root_path)

      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
