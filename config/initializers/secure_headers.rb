SecureHeaders::Configuration.default do |config|
  # Secure cookies only over HTTPS. In local dev/test the app is served over
  # http, so a Secure flag would make the browser drop the session cookie and
  # bounce every request back to the login page.
  config.cookies = {
    secure: Rails.env.local? ? SecureHeaders::OPT_OUT : true,
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
    # Allow mirrored product thumbnails served from the R2 custom domain.
    img_src: (%w['self' data:] + [ENV['R2_PUBLIC_HOST'].presence && "https://#{ENV['R2_PUBLIC_HOST']}"].compact),
    connect_src: %w['self' ws: wss:],
    font_src: %w['self'],
    base_uri: %w['self'],
    form_action: %w['self'],
    frame_ancestors: %w['self']
  }
end
