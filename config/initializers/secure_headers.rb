SecureHeaders::Configuration.default do |config|
  # Opt out of secure_headers' cookie rewriting entirely. On Rack 3 it mangles
  # responses that set multiple Set-Cookie headers — e.g. logging in with
  # "remember me" (session + remember_user_token) — silently dropping the
  # session cookie, so the user authenticates but immediately bounces back to
  # the login page. Rails already applies httponly + samesite=lax natively, and
  # secure is enforced in production via config.force_ssl, so this rewriting is
  # both redundant and harmful.
  config.cookies = SecureHeaders::OPT_OUT

  config.x_frame_options = "SAMEORIGIN"
  config.x_content_type_options = "nosniff"
  config.x_xss_protection = "0"
  config.x_permitted_cross_domain_policies = "none"
  config.referrer_policy = %w[strict-origin-when-cross-origin]

  config.csp = {
    default_src: %w['self'],
    script_src: %w['self' 'unsafe-inline'],
    style_src: %w['self' 'unsafe-inline'],
    # Allow mirrored product thumbnails served from the R2 custom domain.
    img_src: (%w['self' data:] + [ENV['R2_PUBLIC_HOST'].presence && "https://#{ENV['R2_PUBLIC_HOST']}"].compact),
    connect_src: %w['self' ws: wss:],
    font_src: %w['self'],
    base_uri: %w['self'],
    form_action: %w['self'],
    frame_ancestors: %w['self']
  }
end
