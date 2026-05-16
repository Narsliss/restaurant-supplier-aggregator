require 'rails_helper'

RSpec.describe Scrapers::UsFoodsScraper do
  let(:supplier) { create(:supplier, :two_fa) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper) { described_class.new(credential) }

  describe '#bootstrap_api_tokens' do
    # Regression — without an explicit moxe token exchange after fresh login,
    # brand-new credentials had no api_tokens in session_data and the first
    # catalog import raised 'USF API session expired — 2FA login required',
    # mark_failed! the credential within seconds of a successful login.
    context 'when session_data captures a B2C idToken from a fresh login' do
      let(:id_token) { 'eyJhbGciOiJSUzI1NiIsImtpZCI6IkJnUV9RWV9Ea1NrZjVkeEsyOXppM1p6YzRqWjU5UTFWVVhaR19xfakefake' }
      let(:session_blob) do
        {
          'cookies' => {},
          'local_storage' => {
            '_ionicAuth.idToken.74d1fb21-7a0b-4bb6-b8b8-e6d2257a7a98' => id_token,
            'CapacitorStorage.refresh-token' => 'refresh-uuid'
          },
          'session_storage' => {}
        }.to_json
      end

      before { credential.update!(session_data: session_blob) }

      it 'exchanges the idToken via api_client.authenticate_with_id_token' do
        fake_api = instance_double(Scrapers::UsFoodsApi)
        allow(scraper).to receive(:api_client).and_return(fake_api)
        expect(fake_api).to receive(:authenticate_with_id_token).with(id_token).and_return(true)
        scraper.bootstrap_api_tokens
      end

      it 'does not raise when the idToken exchange fails' do
        fake_api = instance_double(Scrapers::UsFoodsApi)
        allow(scraper).to receive(:api_client).and_return(fake_api)
        allow(fake_api).to receive(:authenticate_with_id_token).and_return(false)
        expect { scraper.bootstrap_api_tokens }.not_to raise_error
      end
    end

    context 'when session_data has no idToken' do
      before do
        credential.update!(session_data: { 'cookies' => {}, 'local_storage' => {} }.to_json)
      end

      it 'does not call authenticate_with_id_token' do
        fake_api = instance_double(Scrapers::UsFoodsApi)
        allow(scraper).to receive(:api_client).and_return(fake_api)
        expect(fake_api).not_to receive(:authenticate_with_id_token)
        scraper.bootstrap_api_tokens
      end
    end

    context 'when session_data is blank' do
      before { credential.update!(session_data: nil) }

      it 'returns without raising' do
        expect { scraper.bootstrap_api_tokens }.not_to raise_error
      end
    end
  end
end
