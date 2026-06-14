require 'rails_helper'

RSpec.describe 'SupplierCredentials', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }
  let(:supplier) { create(:supplier, name: 'Test Supplier', code: "test-sup-#{SecureRandom.hex(3)}") }

  before { sign_in owner }

  describe 'GET /supplier_credentials' do
    it 'returns 200' do
      get supplier_credentials_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /supplier_credentials/new' do
    it 'returns 200 for owner' do
      get new_supplier_credential_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /supplier_credentials' do
    it 'creates a new credential with encrypted password' do
      expect {
        post supplier_credentials_path, params: {
          supplier_credential: {
            supplier_id: supplier.id,
            username: 'chef@test.com',
            password: 'Secret123!',
            location_id: location.id
          }
        }
      }.to change(SupplierCredential, :count).by(1)

      created = SupplierCredential.last
      expect(created.supplier).to eq(supplier)
      expect(created.username).to eq('chef@test.com')
      expect(created.encrypted_password).to be_present
      expect(created.encrypted_password).not_to include('Secret123!')
    end

    it 'rejects duplicate credentials for the same supplier at the same location' do
      create(:supplier_credential, user: owner, supplier: supplier, location: location)

      expect {
        post supplier_credentials_path, params: {
          supplier_credential: {
            supplier_id: supplier.id, username: 'chef@test.com', password: 'X', location_id: location.id
          }
        }
      }.not_to change(SupplierCredential, :count)
    end

    it 'rejects credentials for an inactive supplier' do
      supplier.update!(active: false)
      expect {
        post supplier_credentials_path, params: {
          supplier_credential: {
            supplier_id: supplier.id, username: 'x', password: 'y', location_id: location.id
          }
        }
      }.not_to change(SupplierCredential, :count)
    end
  end

  describe 'DELETE /supplier_credentials/:id' do
    let!(:credential) { create(:supplier_credential, user: owner, supplier: supplier, location: location) }

    it 'destroys the credential and redirects' do
      expect {
        delete supplier_credential_path(credential)
      }.to change(SupplierCredential, :count).by(-1)
      expect(response).to redirect_to(supplier_credentials_path)
    end
  end

  describe 'manager (read-only) gate' do
    let!(:credential) { create(:supplier_credential, user: owner, supplier: supplier, location: location) }

    it 'redirects a manager away from creation actions' do
      manager = create(:user)
      create(:membership, user: manager, organization: org, role: 'manager', active: true).tap do |m|
        m.locations << location
      end
      manager.update!(current_organization: org)

      sign_out owner
      sign_in manager
      get new_supplier_credential_path
      expect(response).to be_redirect
    end
  end

  describe 'cross-organization isolation' do
    let!(:credential) { create(:supplier_credential, user: owner, supplier: supplier, location: location) }

    it 'redirects to /supplier_credentials when accessing another org\'s credential' do
      other_user = create(:user, :fully_onboarded)
      sign_out owner
      sign_in other_user

      get supplier_credential_path(credential)
      # Controller redirects with alert when credential not found in scope
      expect(response).to be_redirect
      expect(response.location).to include('/supplier_credentials')
    end
  end

  describe 'failed password-auth credential — Reconnect button' do
    let!(:credential) do
      create(:supplier_credential, user: owner, supplier: supplier, location: location,
                                   status: 'failed', last_error: 'Login failed — not authenticated after both login stages')
    end

    it 'renders a Reconnect button wired to the validate endpoint (re-login with stored password)' do
      get supplier_credentials_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Reconnect')
      # The button drives the existing async validate → 2FA flow via Stimulus.
      expect(response.body).to include('click->credential-validator#startValidation')
      # And the card exposes the validate endpoint the button posts to.
      expect(response.body).to include(validate_supplier_credential_path(credential, format: :json))
      # The redundant "Update Information" link is gone — Edit (always rendered) covers the password-changed case.
      expect(response.body).not_to include('Update Information')
      expect(response.body).to include(edit_supplier_credential_path(credential))
    end

    it 'POST validate re-runs login with the stored credentials (no password retype required)' do
      expect {
        post validate_supplier_credential_path(credential, format: :json)
      }.to have_enqueued_job(ValidateCredentialsJob).with(credential.id)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['status']).to eq('validating')
      expect(credential.reload.status).to eq('pending')
    end
  end

  describe 'auth gate' do
    it 'redirects unauthenticated to sign in' do
      sign_out owner
      get supplier_credentials_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
