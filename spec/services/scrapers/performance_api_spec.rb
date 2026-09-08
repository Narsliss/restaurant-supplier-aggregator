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
end
