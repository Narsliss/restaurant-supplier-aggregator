# frozen_string_literal: true

# Rack::Attack — rate limiting / abuse throttling.
#
# Track-only soak from 2026-04-21 to 2026-04-29 produced zero matches on
# legitimate traffic. Rules below are now in `throttle` mode — exceeding
# the limit returns HTTP 429 with `Retry-After`. The catch-all per-IP
# limit was raised from 300 to 600/min before flipping to give heavy
# real users (Turbo prefetch + status polling + XHR bursts) safe headroom
# while still catching brute-force / credential-stuffing attempts.

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

  # --- Throttles (return 429 when exceeded) ---

  # Login attempts per IP: 10/min
  throttle("throttle/logins/ip", limit: 10, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/users/sign_in"
  end

  # Login attempts per email: 5/min (password spray detection)
  throttle("throttle/logins/email", limit: 5, period: 60.seconds) do |req|
    if req.post? && req.path == "/users/sign_in"
      req.params.dig("user", "email").to_s.downcase.strip.presence
    end
  end

  # Password reset requests per IP: 5/min
  throttle("throttle/password_resets/ip", limit: 5, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/users/password"
  end

  # Signups per IP: 5/min
  throttle("throttle/signups/ip", limit: 5, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/users"
  end

  # Supplier portal logins: 10/min per IP
  throttle("throttle/supplier_logins/ip", limit: 10, period: 60.seconds) do |req|
    req.ip if req.post? && req.path == "/supplier_users/sign_in"
  end

  # Catch-all: 600 requests per minute per IP
  # (raised from 300 when flipping out of track mode — gives heavy real
  # users with Turbo prefetch + status polling + XHR bursts safe headroom
  # while still catching sustained 10 req/s attacks.)
  throttle("throttle/req/ip", limit: 600, period: 60.seconds) do |req|
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
