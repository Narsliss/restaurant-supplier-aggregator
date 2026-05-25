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

  describe '#refresh_known_skus' do
    let(:fake_api) { instance_double(Scrapers::UsFoodsApi, ensure_session!: true) }

    before { allow(scraper).to receive(:api_client).and_return(fake_api) }

    it 'returns zero counts and yields nothing for an empty SKU list' do
      expect(fake_api).not_to receive(:fetch_prices)

      yields = []
      result = scraper.refresh_known_skus([]) { |r| yields << r }

      expect(yields).to be_empty
      expect(result).to eq(updated: 0, missed: 0, batches: 0)
    end

    it 'returns updates with case_price and price_uom for SKUs in the response' do
      allow(fake_api).to receive(:fetch_prices).with([100, 200]).and_return(
        100 => { case_price: 12.34, split_price: nil, price_uom: 'CS', catch_weight: false },
        200 => { case_price: 56.78, split_price: nil, price_uom: 'LB', catch_weight: true }
      )

      yields = []
      result = scraper.refresh_known_skus(%w[100 200]) { |r| yields << r }

      expect(yields.size).to eq(1)
      expect(yields.first[:updates]).to contain_exactly(
        { supplier_sku: '100', current_price: 12.34, price_unit: 'CS' },
        { supplier_sku: '200', current_price: 56.78, price_unit: 'LB' }
      )
      expect(yields.first[:missed]).to be_empty
      expect(result).to eq(updated: 2, missed: 0, batches: 1)
    end

    it 'counts $0 prices as updates (not misses) so no-contract items stay seen' do
      allow(fake_api).to receive(:fetch_prices).with([300]).and_return(
        300 => { case_price: 0.0, split_price: nil, price_uom: '', catch_weight: false }
      )

      result = scraper.refresh_known_skus(['300'])

      expect(result[:updated]).to eq(1)
      expect(result[:missed]).to eq(0)
    end

    it 'defaults price_unit to "CS" when the API returns a blank priceUom' do
      allow(fake_api).to receive(:fetch_prices).with([400]).and_return(
        400 => { case_price: 9.99, split_price: nil, price_uom: '', catch_weight: false }
      )

      scraper.refresh_known_skus(['400']) do |batch|
        expect(batch[:updates].first[:price_unit]).to eq('CS')
      end
    end

    it 'reports SKUs absent from the API response as missed' do
      allow(fake_api).to receive(:fetch_prices).with([500, 600]).and_return(
        500 => { case_price: 1.23, split_price: nil, price_uom: 'CS', catch_weight: false }
        # 600 intentionally absent
      )

      yields = []
      result = scraper.refresh_known_skus(%w[500 600]) { |r| yields << r }

      expect(yields.first[:updates].map { |u| u[:supplier_sku] }).to eq(['500'])
      expect(yields.first[:missed]).to eq(['600'])
      expect(result).to eq(updated: 1, missed: 1, batches: 1)
    end

    it 'splits large SKU lists into batches and yields once per batch' do
      skus = (1..120).map(&:to_s)

      allow(fake_api).to receive(:fetch_prices) do |numbers|
        numbers.to_h { |n| [n, { case_price: 1.0, split_price: nil, price_uom: 'CS', catch_weight: false }] }
      end

      yields = []
      result = scraper.refresh_known_skus(skus) { |r| yields << r }

      # batch_size: 50 → 50 + 50 + 20 = 3 batches
      expect(yields.size).to eq(3)
      expect(yields.map { |y| y[:updates].size }).to eq([50, 50, 20])
      expect(result[:batches]).to eq(3)
      expect(result[:updated]).to eq(120)
    end

    it 'reports all SKUs in a failing batch as missed and continues to the next batch' do
      skus = %w[700 701 800 801]

      allow(fake_api).to receive(:fetch_prices).with([700, 701]).and_raise(StandardError, 'boom')
      allow(fake_api).to receive(:fetch_prices).with([800, 801]).and_return(
        800 => { case_price: 5.5, split_price: nil, price_uom: 'CS', catch_weight: false },
        801 => { case_price: 6.6, split_price: nil, price_uom: 'CS', catch_weight: false }
      )

      result = scraper.refresh_known_skus(skus, batch_size: 2)

      expect(result[:updated]).to eq(2)
      expect(result[:missed]).to eq(2)
      expect(result[:batches]).to eq(2)
    end
  end
end
