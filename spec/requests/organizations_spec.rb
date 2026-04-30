require 'rails_helper'

RSpec.describe 'Organizations', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }

  before { sign_in owner }

  describe 'GET /organization' do
    it 'returns 200' do
      get organization_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /organization/edit (owner-only)' do
    it 'returns 200 for owner' do
      get edit_organization_path
      expect(response).to have_http_status(:ok)
    end

    it 'redirects a manager away' do
      manager = create(:user)
      create(:membership, user: manager, organization: org, role: 'manager', active: true)
      manager.update!(current_organization: org)

      sign_out owner
      sign_in manager
      get edit_organization_path
      expect(response).to be_redirect
    end
  end

  describe 'PATCH /organization' do
    it 'updates basic attributes' do
      patch organization_path, params: { organization: { name: 'Renamed Co' } }
      expect(org.reload.name).to eq('Renamed Co')
    end
  end

  describe 'GET /organization/new (no current_organization)' do
    it 'returns 200 for users without an org' do
      blank_user = create(:user)
      sign_out owner
      sign_in blank_user
      get new_organization_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /organization' do
    it 'creates an org and assigns the user as owner' do
      blank_user = create(:user)
      sign_out owner
      sign_in blank_user

      expect {
        post organization_path, params: {
          organization: {
            name: 'New Co', slug: 'new-co',
            address: '1 X St', city: 'NY', state: 'NY', zip_code: '10001'
          }
        }
      }.to change(Organization, :count).by(1)

      expect(blank_user.reload.current_organization).to be_present
    end
  end
end

RSpec.describe 'Organization Memberships', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:teammate) { org.users.where.not(id: owner.id).first }
  let(:teammate_membership) { teammate.membership_for(org) }

  before { sign_in owner }

  describe 'PATCH /organization/memberships/:id' do
    it 'updates the membership role' do
      patch organization_membership_path(teammate_membership), params: { role: 'chef' }
      expect(teammate_membership.reload.role).to eq('chef')
    end

    it 'rejects an attempt to promote to owner' do
      patch organization_membership_path(teammate_membership), params: { role: 'owner' }
      expect(teammate_membership.reload.role).to eq('manager')
    end
  end

  describe 'DELETE /organization/memberships/:id' do
    it 'deactivates the membership (soft delete)' do
      expect {
        delete organization_membership_path(teammate_membership)
      }.to change { teammate_membership.reload.active }.from(true).to(false)
    end
  end
end

RSpec.describe 'Organization Invitations', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }

  before { sign_in owner }

  describe 'POST /organization/invitations' do
    it 'creates a chef invitation (location_id required for chefs)' do
      expect {
        post organization_invitations_path, params: {
          organization_invitation: {
            email: "newchef-#{SecureRandom.hex(3)}@example.com",
            role: 'chef',
            location_id: location.id
          }
        }
      }.to change(OrganizationInvitation, :count).by(1)
    end
  end

  describe 'auth gate' do
    it 'public accept route does NOT require authentication' do
      sign_out owner
      get '/invitations/sometoken/accept'
      # Returns either 200 or 404 (no such invitation), but NOT a redirect to login
      expect(response).not_to redirect_to(new_user_session_path)
    end
  end
end
