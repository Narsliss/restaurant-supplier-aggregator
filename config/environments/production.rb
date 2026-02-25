require 'active_support/core_ext/integer/time'

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true
  config.cache_store = :solid_cache_store
  config.public_file_server.enabled = ENV['RAILS_SERVE_STATIC_FILES'].present?
  config.active_storage.service = :local
  config.force_ssl = ENV['DISABLE_SSL'].blank?
  config.logger = ActiveSupport::Logger.new(STDOUT)
                                       .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
                                       .then { |logger| ActiveSupport::TaggedLogging.new(logger) }
  config.log_tags = [:request_id]
  config.log_level = ENV.fetch('RAILS_LOG_LEVEL', 'info')
  config.action_mailer.perform_caching = false
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.default_url_options = { host: 'pretty-friendship-production-7e4d.up.railway.app', protocol: 'https' }
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address: 'smtp.sendgrid.net',
    port: 587,
    authentication: :plain,
    user_name: 'apikey',
    password: ENV['SENDGRID_API_KEY'],
    domain: 'pretty-friendship-production-7e4d.up.railway.app',
    enable_starttls_auto: true
  }
  config.i18n.fallbacks = true
  config.active_support.deprecation = :notify
  config.active_support.disallowed_deprecation = :log
  config.active_record.dump_schema_after_migration = false

  # ActionCable
  config.action_cable.url = 'wss://pretty-friendship-production-7e4d.up.railway.app/cable'
  config.action_cable.allowed_request_origins = [
    'https://pretty-friendship-production-7e4d.up.railway.app',
    %r{https://.*\.up\.railway\.app}
  ]
end
