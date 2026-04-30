require 'rails_helper'

RSpec.describe SupplierCredential, type: :model do
  describe 'encryption' do
    let(:credential) { create(:supplier_credential, username: 'chef@test.com', password: 'Secret123!') }

    it 'roundtrips encrypted username and password' do
      reloaded = SupplierCredential.find(credential.id)
      expect(reloaded.username).to eq('chef@test.com')
      expect(reloaded.password).to eq('Secret123!')
    end

    it 'stores ciphertext columns, not plaintext' do
      credential.reload
      expect(credential.encrypted_username).to be_present
      expect(credential.encrypted_username).not_to include('chef@test.com')
      expect(credential.encrypted_password).not_to include('Secret123!')
    end
  end

  describe 'password validation' do
    it 'requires password for password-required suppliers' do
      cred = build(:supplier_credential, password: nil)
      expect(cred).not_to be_valid
      expect(cred.errors[:password]).to be_present
    end

    it 'allows blank password for 2FA-only suppliers' do
      supplier = create(:supplier, :two_fa)
      cred = build(:supplier_credential, supplier: supplier, password: nil)
      expect(cred).to be_valid
    end

    it 'allows blank password for welcome_url suppliers' do
      supplier = create(:supplier, auth_type: 'welcome_url', password_required: false)
      cred = build(:supplier_credential, supplier: supplier, password: nil)
      expect(cred).to be_valid
    end
  end

  describe 'uniqueness' do
    it 'enforces one credential per (user, supplier, location)' do
      user = create(:user)
      supplier = create(:supplier)
      create(:supplier_credential, user: user, supplier: supplier, location: nil)
      duplicate = build(:supplier_credential, user: user, supplier: supplier, location: nil)
      expect(duplicate).not_to be_valid
    end

    it 'allows two credentials for same (user, supplier) at different locations' do
      user = create(:user, :with_organization)
      supplier = create(:supplier)
      org = user.current_organization
      loc_a = create(:location, user: user, organization: org)
      loc_b = create(:location, user: user, organization: org)

      create(:supplier_credential, user: user, supplier: supplier, location: loc_a)
      cred_b = build(:supplier_credential, user: user, supplier: supplier, location: loc_b)
      expect(cred_b).to be_valid
    end
  end

  describe 'status predicates and transitions' do
    let(:credential) { create(:supplier_credential, status: 'pending') }

    it '#active? matches the status string' do
      expect(credential.active?).to be false
      credential.update!(status: 'active')
      expect(credential.active?).to be true
    end

    it '#mark_active! sets last_login_at and clears errors' do
      credential.update!(last_error: 'nope', refresh_failures: 2)
      credential.mark_active!

      expect(credential).to be_active
      expect(credential.last_login_at).to be_within(1.second).of(Time.current)
      expect(credential.last_error).to be_nil
      expect(credential.refresh_failures).to eq(0)
    end

    it '#mark_failed! stores the error message' do
      credential.mark_failed!('bad password')
      expect(credential).to be_failed
      expect(credential.last_error).to eq('bad password')
    end

    it '#mark_on_hold! sets status, account_on_hold, and hold_reason' do
      credential.mark_on_hold!('Compliance review')
      expect(credential.status).to eq('hold')
      expect(credential.account_on_hold).to be true
      expect(credential.hold_reason).to eq('Compliance review')
      expect(credential.on_hold?).to be true
    end
  end

  describe '#record_refresh_failure!' do
    let(:credential) { create(:supplier_credential, status: 'active', refresh_failures: 0) }

    it 'increments without expiring on the first failure' do
      credential.record_refresh_failure!
      expect(credential.refresh_failures).to eq(1)
      expect(credential).to be_active
    end

    it 'expires after MAX_REFRESH_FAILURES consecutive failures' do
      credential.update!(refresh_failures: SupplierCredential::MAX_REFRESH_FAILURES - 1)

      credential.record_refresh_failure!

      expect(credential.refresh_failures).to eq(SupplierCredential::MAX_REFRESH_FAILURES)
      expect(credential).to be_expired
    end
  end

  describe '#session_valid?' do
    let(:credential) { create(:supplier_credential, last_login_at: 1.hour.ago) }

    it 'returns false without session_data' do
      expect(credential.session_valid?).to be false
    end

    it 'returns true within 6h window for password suppliers' do
      credential.update!(session_data: '{"cookies":[]}')
      expect(credential.session_valid?).to be true
    end

    it 'returns false past the 6h window for password suppliers' do
      credential.update!(session_data: '{"cookies":[]}', last_login_at: 7.hours.ago)
      expect(credential.session_valid?).to be false
    end

    it 'uses a 24h window for 2FA-only suppliers' do
      two_fa_supplier = create(:supplier, :two_fa)
      cred = create(:supplier_credential, supplier: two_fa_supplier, session_data: '{"x":1}', last_login_at: 12.hours.ago)
      expect(cred.session_valid?).to be true
    end
  end

  describe '#health_message' do
    it 'reports the hold reason when account_on_hold' do
      cred = build(:supplier_credential, account_on_hold: true, hold_reason: 'Past due')
      expect(cred.health_message).to eq('Account on hold: Past due')
    end

    it 'falls back to last_error for failed status' do
      cred = build(:supplier_credential, status: 'failed', last_error: 'invalid login')
      expect(cred.health_message).to eq('invalid login')
    end

    it 'truncates long error messages' do
      cred = build(:supplier_credential, status: 'failed', last_error: 'x' * 200)
      expect(cred.health_message.length).to be <= 141
      expect(cred.health_message).to end_with('…')
    end

    it 'returns a fixed phrase for expired status' do
      cred = build(:supplier_credential, status: 'expired')
      expect(cred.health_message).to eq('Session expired — please re-validate.')
    end
  end

  describe '#clear_session!' do
    it 'wipes session_data' do
      cred = create(:supplier_credential, session_data: '{"cookies":[]}')
      cred.clear_session!
      expect(cred.reload.session_data).to be_nil
    end
  end

  describe 'scopes' do
    let!(:active) { create(:supplier_credential, status: 'active', last_login_at: 1.hour.ago) }
    let!(:stale_active) { create(:supplier_credential, status: 'active', last_login_at: 7.hours.ago) }
    let!(:expired) { create(:supplier_credential, status: 'expired') }
    let!(:failed) { create(:supplier_credential, status: 'failed') }

    it '.active filters by active status' do
      expect(SupplierCredential.active).to include(active, stale_active)
      expect(SupplierCredential.active).not_to include(expired, failed)
    end

    it '.needs_refresh returns credentials older than 6h' do
      expect(SupplierCredential.needs_refresh).to include(stale_active)
      expect(SupplierCredential.needs_refresh).not_to include(active)
    end

    it '.needs_user_attention returns failed/expired/hold credentials' do
      expect(SupplierCredential.needs_user_attention).to include(expired, failed)
      expect(SupplierCredential.needs_user_attention).not_to include(active)
    end
  end
end
