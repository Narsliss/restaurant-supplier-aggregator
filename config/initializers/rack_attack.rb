# frozen_string_literal: true

# Rack::Attack — rate limiting / abuse throttling.
#
# DEPLOYED IN TRACK-ONLY MODE on 2026-04-21. Rules log "would-have-blocked"
# events via Rails.logger but do NOT actually block requests. After 24-48h
# soak, review Railway logs for lines tagged [Rack::Attack]. If only
# attacker-like traffic is flagged, flip `track` calls to `throttle` in a
# follow-up commit.

class Rack::Attack
  # Counter storage — uses Rails.cache (Solid Cache in production).
  Rack::Attack.cache.store = Rails.cache

  # --- Safelists (never tracked or throttled) ---

  # Railway health check — hit constantly by the platform
  safelist("allow/health-check") do |req|
    req.path == "/up"
  end

  # Stripe webhooks — retries must go through
  safelist("allow/webhooks") do |req|
    req.path.start_with?("/webhooks/")
  end

  # ActionCable — long-lived WebSocket
  safelist("allow/actioncable") do |req|
    req.path.start_with?("/cable")
  end

  # --- Tracks (log only, do NOT block) ---

  # Login attempts per IP: 10/min
  track("track/logins/ip", limit: 10, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/users/sign_in"
  end

  # Login attempts per email: 5/min (password spray detection)
  track("track/logins/email", limit: 5, period: 60.seconds) do |req|
    if req.post? && req.path == "/users/sign_in"
      req.params.dig("user", "email").to_s.downcase.strip.presence
    end
  end

  # Password reset requests per IP: 5/min
  track("track/password_resets/ip", limit: 5, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/users/password"
  end

  # Signups per IP: 5/min
  track("track/signups/ip", limit: 5, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/users"
  end

  # Supplier portal logins: 10/min per IP
  track("track/supplier_logins/ip", limit: 10, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/supplier_users/sign_in"
  end

  # Catch-all: 300 requests per minute per IP
  track("track/req/ip", limit: 300, period: 60.seconds) do |req|
    req.ip
  end
end

# Log every track match via ActiveSupport::Notifications.
ActiveSupport::Notifications.subscribe("rack.attack") do |_name, _start, _finish, _req_id, payload|
  req = payload[:req] || payload[:request]
  next unless req

  match_type = req.env["rack.attack.match_type"]
  match_name = req.env["rack.attack.matched"]
  match_data = req.env["rack.attack.match_data"]

  Rails.logger.warn(
    "[Rack::Attack] #{match_type} matched=#{match_name} " \
    "ip=#{req.ip} path=#{req.path} method=#{req.request_method} " \
    "count=#{match_data&.dig(:count)}/#{match_data&.dig(:limit)}"
  )
end
