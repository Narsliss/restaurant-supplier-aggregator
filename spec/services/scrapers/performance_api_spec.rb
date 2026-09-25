require 'rails_helper'

RSpec.describe Scrapers::PerformanceApi do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:api) { described_class.new(credential) }

  # MSAL.js cache entries as PerformanceScraper persists them from browser
  # storage. Keys follow MSAL's scheme; values are JSON strings with the
  # token in "secret" and the granted scopes in "target".
  def msal_access_entry(secret:, target:, expires_at:)
    {
      'credentialType' => 'AccessToken',
      'secret' => secret,
      'target' => target,
      'expiresOn' => expires_at.to_i.to_s
    }.to_json
  end

  def session_blob(local_storage)
    { 'cookies' => {}, 'local_storage' => local_storage, 'session_storage' => {} }.to_json
  end

  let(:api_scope_target) do
    'https://pfgcustomerfirst.onmicrosoft.com/api/customer-first-site-api openid profile'
  end

  describe '#restore_session' do
    it 'returns false when there is no session data' do
      credential.update!(session_data: nil)
      expect(api.restore_session).to be(false)
    end

    it 'loads a valid API-scope access token from the MSAL cache' do
      credential.update!(session_data: session_blob(
        'abc-tenant-accesstoken-client-tenant-scopes--' =>
          msal_access_entry(secret: 'live-token', target: api_scope_target, expires_at: 1.hour.from_now)
      ))

      expect(api.restore_session).to be(true)
      expect(api.token_expired?).to be(false)
    end

    it 'ignores access tokens for other scopes (e.g. Graph) instead of using them against the middleware' do
      credential.update!(session_data: session_blob(
        'abc-tenant-accesstoken-client-tenant-graph--' =>
          msal_access_entry(secret: 'graph-token', target: 'https://graph.microsoft.com/.default', expires_at: 1.hour.from_now)
      ))

      expect(api.restore_session).to be(false)
    end

    it 'refreshes via the B2C token endpoint when the access token is expired and a refresh token exists' do
      credential.update!(session_data: session_blob(
        'abc-tenant-accesstoken-client-tenant-scopes--' =>
          msal_access_entry(secret: 'stale-token', target: api_scope_target, expires_at: 1.hour.ago),
        'abc-tenant-refreshtoken-client--' =>
          { 'credentialType' => 'RefreshToken', 'secret' => 'refresh-secret' }.to_json
      ))

      stub_request(:post, described_class::TOKEN_ENDPOINT)
        .with(body: hash_including('grant_type' => 'refresh_token', 'refresh_token' => 'refresh-secret',
                                   'client_id' => described_class::CLIENT_ID))
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { access_token: 'fresh-token', refresh_token: 'new-refresh', expires_in: 3600 }.to_json)

      expect(api.restore_session).to be(true)
      expect(api.token_expired?).to be(false)
    end

    it 'returns false when the refresh is rejected (dead refresh token)' do
      credential.update!(session_data: session_blob(
        'abc-tenant-refreshtoken-client--' =>
          { 'credentialType' => 'RefreshToken', 'secret' => 'dead-refresh' }.to_json
      ))

      stub_request(:post, described_class::TOKEN_ENDPOINT)
        .to_return(status: 400, body: { error: 'invalid_grant' }.to_json)

      expect(api.restore_session).to be(false)
    end
  end

  describe '#call' do
    before do
      credential.update!(session_data: session_blob(
        'abc-tenant-accesstoken-client-tenant-scopes--' =>
          msal_access_entry(secret: 'live-token', target: api_scope_target, expires_at: 1.hour.from_now)
      ))
      api.restore_session
    end

    it 'POSTs to the RPC route with the bearer token and parses JSON' do
      stub_request(:post, "#{described_class::API_BASE}/api/Order/V1/GetOrderCart")
        .with(headers: { 'Authorization' => 'Bearer live-token' })
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { 'cart' => [] }.to_json)

      expect(api.call('Order', 'GetOrderCart', {})).to eq('cart' => [])
    end

    # The middleware returns HTTP 203 instead of 401 when unauthenticated.
    # Treating 203 as success would silently import empty/garbage payloads.
    it 'raises AuthError on the HTTP 203 unauthenticated quirk' do
      stub_request(:post, "#{described_class::API_BASE}/api/Order/V1/GetOrderCart")
        .to_return(status: 203, body: '')

      expect { api.call('Order', 'GetOrderCart', {}) }
        .to raise_error(described_class::AuthError, /203/)
    end

    it 'raises AuthError when no token was loaded' do
      fresh = described_class.new(credential)
      expect { fresh.call('Order', 'GetOrderCart') }
        .to raise_error(described_class::AuthError, /restore_session/)
    end
  end

  describe 'catalog methods' do
    before do
      credential.update!(session_data: session_blob(
        'abc-tenant-accesstoken-client-tenant-scopes--' =>
          msal_access_entry(secret: 'live-token', target: api_scope_target, expires_at: 1.hour.from_now)
      ))
      api.restore_session

      # account_context: GetCurrentUserSite (UserCustomers) + GetActiveOrder
      allow(api).to receive(:call).and_call_original
      allow(api).to receive(:call).with('Site', 'GetCurrentUserSite', nil, http_method: :get)
        .and_return({ 'ResultObject' => { 'UserCustomers' => [{
          'CustomerId' => 'cust-guid', 'OperationCompanyNumber' => '790', 'BusinessUnitKey' => 0,
          'CustomerNumber' => '12345', 'CustomerName' => 'Las Noches'
        }] } })
      allow(api).to receive(:call).with('OrderEntryHeader', 'GetActiveOrder', nil, http_method: :get, query: { 'CustomerId' => 'cust-guid' })
        .and_return({ 'ResultObject' => { 'OrderEntryHeaderId' => 'oeh-1', 'DeliveryDate' => '2026-09-09T00:00:00' } })
    end

    describe '#account_context' do
      it 'derives customer/opco/order context and memoizes it' do
        ctx = api.account_context
        expect(ctx).to include(customer_id: 'cust-guid', operation_company_number: '790',
                               order_entry_header_id: 'oeh-1', delivery_date: '2026-09-09T00:00:00')
        api.account_context # second call must not re-fetch
        expect(api).to have_received(:call).with('Site', 'GetCurrentUserSite', nil, http_method: :get).once
      end

      it 'falls back to the no-active-order sentinel when there is no open draft' do
        allow(api).to receive(:call).with('OrderEntryHeader', 'GetActiveOrder', nil, http_method: :get, query: { 'CustomerId' => 'cust-guid' })
          .and_return({ 'ResultObject' => { 'OrderEntryHeaderId' => nil, 'DeliveryDate' => '2026-09-25T00:00:00' } })

        expect(api.account_context[:order_entry_header_id]).to eq(described_class::NO_ACTIVE_ORDER)
      end

      it 'raises when the account has no customers' do
        allow(api).to receive(:call).with('Site', 'GetCurrentUserSite', nil, http_method: :get)
          .and_return({ 'ResultObject' => { 'UserCustomers' => [] } })
        expect { api.account_context }.to raise_error(described_class::ApiError, /No UserCustomers/)
      end
    end

    describe '#search_catalog' do
      it 'posts the account-scoped body and returns the ResultObject' do
        allow(api).to receive(:call).with('ProductCatalog', 'SearchProductCatalog', hash_including(
          'OperationCompanyNumber' => '790', 'CustomerId' => 'cust-guid', 'QueryText' => 'chicken',
          'CurrentPageNumber' => 2, 'Skip' => 50, 'LoadPricing' => false
        )).and_return({ 'IsSuccess' => true, 'ResultObject' => { 'CatalogProducts' => [] } })

        expect(api.search_catalog('chicken', page: 2, page_size: 25)).to eq('CatalogProducts' => [])
      end

      it 'raises ApiError when the envelope reports failure' do
        allow(api).to receive(:call).with('ProductCatalog', 'SearchProductCatalog', anything)
          .and_return({ 'IsSuccess' => false, 'ErrorMessages' => ['nope'], 'ResultObject' => nil })
        expect { api.search_catalog('chicken') }.to raise_error(described_class::ApiError, /nope/)
      end
    end

    describe '#list_headers' do
      it 'returns the ResultObject array of guide headers' do
        allow(api).to receive(:call).with('ProductListHeader', 'GetProductListHeaders', nil,
                                          http_method: :get, query: { 'customerId' => 'cust-guid' })
          .and_return({ 'ResultObject' => [{ 'ProductListHeaderId' => 'g1', 'ProductListTitle' => 'alfios' }] })
        expect(api.list_headers).to eq([{ 'ProductListHeaderId' => 'g1', 'ProductListTitle' => 'alfios' }])
      end
    end

    describe '#list_products' do
      it 'flattens ProductListCategories[].Products[] into product entries' do
        allow(api).to receive(:call).with('ProductListSearch', 'SearchProductList', hash_including(
          'ProductListHeaderId' => 'g1', 'CustomerId' => 'cust-guid'
        )).and_return({ 'IsSuccess' => true, 'ResultObject' => { 'ProductListCategories' => [
          { 'CategoryTitle' => 'Uncategorized', 'Products' => [
            { 'Sequence' => 0, 'Product' => { 'ProductNumber' => '328740' } },
            { 'Sequence' => 1, 'Product' => { 'ProductNumber' => '543638' } }
          ] }
        ] } })

        entries = api.list_products('g1')
        expect(entries.map { |e| e[:product]['ProductNumber'] }).to eq(%w[328740 543638])
        expect(entries.first).to include(category_title: 'Uncategorized', sequence: 0)
      end

      it 'raises ApiError when the envelope reports failure' do
        allow(api).to receive(:call).with('ProductListSearch', 'SearchProductList', anything)
          .and_return({ 'IsSuccess' => false, 'ErrorMessages' => ['bad'], 'ResultObject' => nil })
        expect { api.list_products('g1') }.to raise_error(described_class::ApiError, /bad/)
      end
    end

    describe '#fetch_prices' do
      it 'returns a ProductKey=>price map and drops zero/blank prices' do
        allow(api).to receive(:call).with('CustomerProductPrice', 'GetOrderEntryCustomerProductPrice', anything)
          .and_return({ 'ResultObject' => { 'CustomerProductPrices' => [
            { 'ProductKey' => '541928', 'Price' => 42.19 },
            { 'ProductKey' => '999', 'Price' => 0 },
            { 'ProductKey' => '888', 'Price' => nil }
          ] } })

        expect(api.fetch_prices(%w[541928 999 888])).to eq('541928' => 42.19)
      end
    end
  end
end
