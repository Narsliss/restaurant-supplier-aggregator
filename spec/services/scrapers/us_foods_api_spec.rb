require 'rails_helper'

RSpec.describe Scrapers::UsFoodsApi do
  let(:supplier) { create(:supplier, :two_fa) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:api) { described_class.new(credential) }

  describe '#restore_session' do
    # Regression — fresh 2FA logins were stranding new chefs with status=failed
    # within seconds of a successful login. The browser captures the B2C
    # idToken at _ionicAuth.idToken.<guid> but the SPA doesn't always write
    # CapacitorStorage.auth-response (the moxe-exchanged response) in time.
    # Without a fallback, the first import after login raised
    # 'USF API session expired — 2FA login required' and flipped the
    # brand-new credential to failed.
    context 'when session_data has only a B2C idToken (no api_tokens, no CapacitorStorage.auth-response)' do
      let(:id_token) { 'B2C_ID_TOKEN_PAYLOAD' }
      let(:session_data) do
        {
          'cookies' => {},
          'local_storage' => {
            '_ionicAuth.idToken.74d1fb21-7a0b-4bb6-b8b8-e6d2257a7a98' => id_token,
            'CapacitorStorage.refresh-token' => 'some-uuid',
            'CapacitorStorage.auth-context' => '{"divisionNumber":1103,"customerNumber":12345,"departmentNumber":0}'
          },
          'session_storage' => {}
        }.to_json
      end

      before { credential.update!(session_data: session_data) }

      it 'exchanges the idToken for moxe API tokens and returns true' do
        expect(api).to receive(:authenticate_with_id_token).with(id_token).and_return(true)
        expect(api.restore_session).to be(true)
      end

      it 'returns false when the idToken exchange fails (e.g. expired token)' do
        expect(api).to receive(:authenticate_with_id_token).with(id_token).and_return(false)
        expect(api.restore_session).to be(false)
      end
    end

    context 'when session_data has api_tokens with a valid access token' do
      let(:session_data) do
        {
          'api_tokens' => {
            'access_token' => 'live-access-token',
            'refresh_token' => 'refresh-uuid',
            'expires_at' => 1.hour.from_now.iso8601,
            'auth_context' => { 'division_number' => 1, 'customer_number' => 2, 'department_number' => 0 }
          }
        }.to_json
      end

      before { credential.update!(session_data: session_data) }

      it 'does not invoke the idToken fallback' do
        allow(api).to receive(:get_identity).and_return('userId' => '999')
        expect(api).not_to receive(:authenticate_with_id_token)
        expect(api.restore_session).to be(true)
      end
    end

    context 'when session_data is blank' do
      it 'returns false without calling authenticate_with_id_token' do
        credential.update!(session_data: nil)
        expect(api).not_to receive(:authenticate_with_id_token)
        expect(api.restore_session).to be(false)
      end
    end
  end
end
