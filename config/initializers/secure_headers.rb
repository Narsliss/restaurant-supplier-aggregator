SecureHeaders::Configuration.default do |config|
  config.cookies = {
    secure: true,
    httponly: true,
    samesite: { lax: true }
  }

  config.x_frame_options = "SAMEORIGIN"
  config.x_content_type_options = "nosniff"
  config.x_xss_protection = "0"
  config.x_permitted_cross_domain_policies = "none"
  config.referrer_policy = %w[strict-origin-when-cross-origin]

  config.csp = {
    default_src: %w['self'],
    script_src: %w['self' 'unsafe-inline'],
    style_src: %w['self' 'unsafe-inline'],
    img_src: %w['self' data:],
    connect_src: %w['self' ws: wss:],
    font_src: %w['self'],
    base_uri: %w['self'],
    form_action: %w['self'],
    frame_ancestors: %w['self']
  }
end
