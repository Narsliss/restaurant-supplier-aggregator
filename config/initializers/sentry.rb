if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.environment = Rails.env
    config.release = ENV["RAILWAY_GIT_COMMIT_SHA"].presence ||
                     ENV["GIT_COMMIT_SHA"].presence ||
                     "unknown"

    config.breadcrumbs_logger = [:active_support_logger, :http_logger]

    config.send_default_pii = false

    config.excluded_exceptions += [
      "ActiveRecord::RecordNotFound",
      "ActionController::RoutingError",
      "ActionController::InvalidAuthenticityToken",
      "ActionController::UnknownFormat",
      "ActionController::ParameterMissing"
    ]

    config.traces_sample_rate = 0.0
  end
end
