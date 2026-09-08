# frozen_string_literal: true

module Scrapers
  # Direct API client for Performance Foodservice (CustomerFirst platform).
  #
  # CustomerFirst's middleware exposes RPC-style routes:
  #   https://apps-zz-cusfst-mw-p-eus01.azurewebsites.net/api/{Service}/V1/{Method}
  #
  # Authentication:
  #   - PerformanceScraper logs in via Azure AD B2C (email + password) and saves
  #     the SPA's MSAL.js cache (localStorage + sessionStorage) into session_data
  #   - MSAL cache entries hold the API access token (key contains "-accesstoken-",
  #     value JSON has "secret", "target" = scopes, "expiresOn" = unix seconds)
  #     and a refresh token (key contains "-refreshtoken-")
  #   - Access tokens are refreshed directly against the B2C token endpoint
  #     (public client + refresh_token grant), so no browser is needed until
  #     the refresh token itself dies
  #
  # Quirk: the middleware returns HTTP 203 (not 401) when unauthenticated —
  # treat 203 as an auth failure, never as success.
  class PerformanceApi
    API_BASE = 'https://apps-zz-cusfst-mw-p-eus01.azurewebsites.net'
    API_SCOPE_HOST = 'customer-first-site-api'
    CLIENT_ID = 'c68e7fae-80a1-42db-bd89-3fb37d1224a2'
    TOKEN_ENDPOINT = 'https://pfgcustomerfirst.b2clogin.com/pfgcustomerfirst.onmicrosoft.com/b2c_1a_signup_signin/oauth2/v2.0/token'

    class ApiError < StandardError; end
    class AuthError < ApiError; end

    attr_reader :credential, :logger

    def initialize(credential)
      @credential = credential
      @logger = Rails.logger
      @access_token = nil
      @refresh_token = nil
      @token_expires_at = nil
      @token_scopes = nil
    end

    # Load API tokens from the MSAL cache the scraper persisted.
    # Returns true when a usable (or refreshable) token is found.
    def restore_session
      raw = credential.session_data
      return false if raw.blank?

      data = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end
      storage = (data['local_storage'] || {}).merge(data['session_storage'] || {})

      access_entry = msal_entry(storage, '-accesstoken-') { |v| v['target'].to_s.include?(API_SCOPE_HOST) }
      refresh_entry = msal_entry(storage, '-refreshtoken-')

      if access_entry
        @access_token = access_entry['secret']
        @token_scopes = access_entry['target']
        @token_expires_at = access_entry['expiresOn'].to_i.positive? ? Time.zone.at(access_entry['expiresOn'].to_i) : nil
      end
      @refresh_token = refresh_entry && refresh_entry['secret']

      if @access_token.present? && !token_expired?
        logger.info "[Performance-API] Session restored from MSAL cache (expires #{@token_expires_at})"
        return true
      end

      if @refresh_token.present?
        logger.info '[Performance-API] Access token missing/expired, refreshing via B2C...'
        return true if refresh_access_token
      end

      logger.info '[Performance-API] No usable API token in session data'
      false
    rescue StandardError => e
      logger.warn "[Performance-API] Session restore failed: #{e.class}: #{e.message}"
      false
    end

    # Public-client refresh against the B2C token endpoint.
    def refresh_access_token
      return false if @refresh_token.blank?

      scope = @token_scopes.presence || "openid offline_access https://pfgcustomerfirst.onmicrosoft.com/api/#{API_SCOPE_HOST}"
      uri = URI(TOKEN_ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri.request_uri)
      req.set_form_data(
        'client_id' => CLIENT_ID,
        'grant_type' => 'refresh_token',
        'refresh_token' => @refresh_token,
        'scope' => scope
      )
      res = http.request(req)

      unless res.is_a?(Net::HTTPSuccess)
        logger.warn "[Performance-API] Token refresh failed: HTTP #{res.code} #{res.body.to_s.truncate(300)}"
        return false
      end

      payload = JSON.parse(res.body)
      @access_token = payload['access_token']
      @refresh_token = payload['refresh_token'] if payload['refresh_token'].present?
      @token_expires_at = Time.current + payload['expires_in'].to_i
      logger.info "[Performance-API] Access token refreshed (expires #{@token_expires_at})"
      @access_token.present?
    rescue StandardError => e
      logger.warn "[Performance-API] Token refresh error: #{e.class}: #{e.message}"
      false
    end

    def token_expired?
      @token_expires_at.nil? || @token_expires_at <= Time.current + 60
    end

    # Decoded claims from the current access token (identity sanity check
    # without hitting the API). Returns {} when no token is loaded.
    def token_claims
      return {} if @access_token.blank?

      payload = @access_token.split('.')[1]
      return {} if payload.blank?

      JSON.parse(Base64.urlsafe_decode64(payload + '=' * (-payload.length % 4)))
    rescue StandardError
      {}
    end

    # Generic RPC call: call('Order', 'GetOrderCart', body). The middleware is
    # POST-heavy; pass http_method: :get for the few GET-style routes.
    def call(service, method, body = nil, http_method: :post)
      raise AuthError, 'No access token — call restore_session first' if @access_token.blank?

      uri = URI("#{API_BASE}/api/#{service}/V1/#{method}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30

      req = http_method == :get ? Net::HTTP::Get.new(uri.request_uri) : Net::HTTP::Post.new(uri.request_uri)
      req['Authorization'] = "Bearer #{@access_token}"
      req['Accept'] = 'application/json'
      if body && http_method != :get
        req['Content-Type'] = 'application/json'
        req.body = body.to_json
      end

      res = http.request(req)

      # CustomerFirst returns 203 Non-Authoritative instead of 401 when the
      # bearer token is missing/invalid. Never treat it as a good response.
      raise AuthError, "Unauthenticated (HTTP #{res.code}) for #{service}/#{method}" if res.code.to_i == 203 || res.code.to_i == 401

      unless res.is_a?(Net::HTTPSuccess)
        raise ApiError, "HTTP #{res.code} for #{service}/#{method}: #{res.body.to_s.truncate(300)}"
      end

      res.body.present? ? JSON.parse(res.body) : nil
    end

    private

    # Find the first MSAL cache entry whose key contains `marker` and whose
    # JSON value passes the optional filter block.
    def msal_entry(storage, marker)
      storage.each do |key, value|
        next unless key.to_s.downcase.include?(marker)

        parsed = begin
          JSON.parse(value)
        rescue StandardError
          nil
        end
        next unless parsed.is_a?(Hash) && parsed['secret'].present?
        next if block_given? && !yield(parsed)

        return parsed
      end
      nil
    end
  end
end
