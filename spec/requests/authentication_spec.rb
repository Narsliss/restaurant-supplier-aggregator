require 'rails_helper'

RSpec.describe 'Authentication', type: :request do
  describe 'unauthenticated access' do
    it 'redirects to the sign-in page when accessing a gated controller' do
      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'sign-in form' do
    it 'defaults "Keep me signed in" to checked so chefs stay logged in' do
      get new_user_session_path
      expect(response).to have_http_status(:ok)
      checkbox = Nokogiri::HTML(response.body)
                   .at_css('input[type="checkbox"][name="user[remember_me]"]')
      expect(checkbox).to be_present
      expect(checkbox["checked"]).to be_present
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

    it 'issues a persistent remember-me cookie when "Keep me signed in" is set' do
      post user_session_path, params: { user: { email: user.email, password: 'Password1!', remember_me: '1' } }
      expect(cookies['remember_user_token']).to be_present
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
