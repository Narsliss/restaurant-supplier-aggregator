require 'rails_helper'

RSpec.describe 'Locations', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }

  before { sign_in owner }

  describe 'GET /locations' do
    it 'returns 200' do
      get locations_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /locations/new' do
    it 'returns 200 for owner' do
      get new_location_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /locations' do
    it 'creates a new location and redirects' do
      expect {
        post locations_path, params: {
          location: {
            name: 'Second Restaurant', address: '99 Side St',
            city: 'Brooklyn', state: 'NY', zip_code: '11201'
          }
        }
      }.to change(Location, :count).by(1)
      expect(response).to be_redirect
    end

    it 'rejects invalid params (no name)' do
      expect {
        post locations_path, params: { location: { name: '' } }
      }.not_to change(Location, :count)
    end
  end

  describe 'POST /locations/switch' do
    let!(:other_location) { create(:location, user: owner, organization: org) }

    it 'updates session current_location and returns 200' do
      post switch_location_path, params: { location_id: other_location.id }
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'auth gate' do
    it 'redirects unauthenticated to sign in' do
      sign_out owner
      get locations_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'manager (non-owner) write gate' do
    it 'redirects a manager away from new' do
      manager = create(:user)
      create(:membership, user: manager, organization: org, role: 'manager', active: true)
      manager.update!(current_organization: org)

      sign_out owner
      sign_in manager
      get new_location_path
      expect(response).to be_redirect
    end
  end
end
