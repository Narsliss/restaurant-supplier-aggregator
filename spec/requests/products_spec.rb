require 'rails_helper'

RSpec.describe 'Products', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:super_admin) do
    User.where(role: 'super_admin').destroy_all
    create(:user, :super_admin)
  end

  describe 'GET /products/search (catalog search)' do
    it 'is accessible to any authenticated user (JSON)' do
      sign_in owner
      get search_products_path(format: :json), params: { q: 'tomato' }
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /products (super_admin only)' do
    it 'redirects regular users away' do
      sign_in owner
      get products_path
      expect(response).to be_redirect
      expect(response.location).not_to include('/products')
    end

    it 'returns 200 for super_admin' do
      sign_in super_admin
      get products_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'auth gate' do
    it 'redirects unauthenticated to sign in' do
      get products_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
