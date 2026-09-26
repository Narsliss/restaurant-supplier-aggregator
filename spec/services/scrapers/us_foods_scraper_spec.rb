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

    # Sep 25 2026: USF's "0" came with an error every time we checked it —
    # 1104 DISCONTINUED PRODUCT, 1102 DOES NOT EXIST, 1106 PRODUCT IS
    # PROPRIETARY. Stored as $0 it read as an orderable $0.00 item.
    it 'reports a discontinued product as seen but priceless, never as a $0 price' do
      allow(fake_api).to receive(:fetch_prices).with([300]).and_return(
        300 => { case_price: 0.0, split_price: 0.0, price_uom: '', catch_weight: false,
                 error_number: 1104, error_message: 'PRODUCT ERROR - DISCONTINUED PRODUCT' }
      )

      yields = []
      result = scraper.refresh_known_skus(['300']) { |r| yields << r }

      expect(yields.first[:updates]).to eq([{ supplier_sku: '300', current_price: nil, price_unit: nil,
                                             unavailable: true, discontinued: true }])
      expect(result).to include(updated: 1, missed: 0)
    end

    it 'reports a product reserved for other customers as priceless but not discontinued' do
      allow(fake_api).to receive(:fetch_prices).with([301]).and_return(
        301 => { case_price: 0.0, split_price: 0.0, price_uom: '', catch_weight: false,
                 error_number: 1106, error_message: 'PRODUCT ERROR - PRODUCT IS PROPRIETARY' }
      )

      scraper.refresh_known_skus(['301']) do |batch|
        expect(batch[:updates].first).to include(current_price: nil, unavailable: true, discontinued: false)
      end
    end

    it 'still passes through a price that came with no error' do
      allow(fake_api).to receive(:fetch_prices).with([302]).and_return(
        302 => { case_price: 0.0, split_price: nil, price_uom: 'CS', catch_weight: false, error_number: 0 }
      )

      scraper.refresh_known_skus(['302']) do |batch|
        expect(batch[:updates].first).to eq(supplier_sku: '302', current_price: 0.0, price_unit: 'CS')
      end
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

  describe '#choose_mfa_method' do
    def choose(**opts)
      scraper.send(:choose_mfa_method, **opts)
    end

    it 'uses email when the account has a real address on file' do
      method, prompt, type = choose(email_available: true, email_addr: 'c*******4@gmail.com',
                                    text_available: true, text_phone: '***-***-1126')

      expect(method).to eq('Email')
      expect(type).to eq('email')
      expect(prompt).to include('c*******4@gmail.com')
    end

    # Regression — phone-only accounts still get a button#Email, labelled
    # "Add your email address". Choosing it starts B2C's email-enrollment
    # journey, which never redirects back to usfoods.com, so validation failed
    # every time and the chef was told a code went to "Add your email address".
    it 'falls back to text when the email option is the add-an-email prompt' do
      method, prompt, type = choose(email_available: true, email_addr: 'Add your email address',
                                    text_available: true, text_phone: '***-***-1017')

      expect(method).to eq('Text')
      expect(type).to eq('sms')
      expect(prompt).to include('***-***-1017')
      expect(prompt).not_to include('Add your email address')
    end

    it 'falls back to text when the email label is missing' do
      method, = choose(email_available: true, email_addr: nil, text_available: true, text_phone: '***-***-1017')

      expect(method).to eq('Text')
    end

    it 'raises when neither option is usable' do
      expect do
        choose(email_available: true, email_addr: 'Add your email address', text_available: false, text_phone: nil)
      end.to raise_error(Scrapers::BaseScraper::ScrapingError, /No usable MFA option/)
    end
  end

  describe '#back_on_app?' do
    # Regression — US Foods moved Azure B2C behind a custom domain
    # (identity.usfoods.com). The old check was
    #   url.include?('usfoods.com') && !url.include?('b2clogin.com')
    # which the custom domain satisfies, so the post-MFA loop declared success
    # while still parked on the B2C SelfAsserted page. The KMSI prompt was never
    # clicked, no app session was ever established, and the failure surfaced as
    # an unrelated hidden B2C validation string.
    it 'does not treat the B2C custom domain as the app' do
      url = 'https://identity.usfoods.com/usfoodsb2cprod.onmicrosoft.com/' \
            'B2C_1A_SignIn_SellersAndCustomers/api/SelfAsserted/confirmed?csrf_token=x'

      expect(scraper.send(:back_on_app?, url)).to be false
      expect(scraper.send(:on_identity_provider?, url)).to be true
    end

    it 'does not treat b2clogin.com as the app' do
      url = 'https://usfoodsb2cprod.b2clogin.com/usfoodsb2cprod.onmicrosoft.com/oauth2/v2.0/authorize'

      expect(scraper.send(:back_on_app?, url)).to be false
    end

    it 'recognises the authenticated app, including the OAuth landing URL' do
      expect(scraper.send(:back_on_app?, 'https://order.usfoods.com/desktop/home')).to be true
      expect(scraper.send(:back_on_app?, 'https://order.usfoods.com/desktop/?code=abc&state=xyz')).to be true
    end

    it 'treats a blank URL as not-yet-redirected' do
      expect(scraper.send(:back_on_app?, '')).to be false
      expect(scraper.send(:back_on_app?, nil)).to be false
    end
  end

  describe '.price_error' do
    it 'reads discontinued and does-not-exist as discontinued' do
      expect(described_class.price_error(error_number: 1104)).to eq(:discontinued)
      expect(described_class.price_error(error_number: 1102)).to eq(:discontinued)
    end

    it 'reads any other error as unavailable to this account' do
      expect(described_class.price_error(error_number: 1106)).to eq(:unavailable)
    end

    it 'reads no error (or no price record) as a real price' do
      expect(described_class.price_error(error_number: 0, case_price: 12.5)).to be_nil
      expect(described_class.price_error(nil)).to be_nil
    end
  end

  describe '#format_list_item (order-guide sync)' do
    let(:product) { { 'summary' => { 'brand' => 'PACKER', 'productDescTxtl' => 'TOMATO, HEIRLOOM', 'salesPackSize' => '10 LB' } } }

    it 'stores no price when USF answers with an error' do
      price = { case_price: 0.0, split_price: 0.0, price_uom: '', error_number: 1104 }

      row = scraper.send(:format_list_item, 6292155, product, price, 0)

      expect(row[:price]).to be_nil
      expect(row[:piece_price]).to be_nil
    end

    it 'keeps a real price exactly as before' do
      price = { case_price: 39.05, split_price: 4.1, price_uom: 'CS', error_number: 0 }

      row = scraper.send(:format_list_item, 6292155, product, price, 0)

      expect(row).to include(price: 39.05, piece_price: 4.1, price_unit: 'CS')
    end
  end
end
