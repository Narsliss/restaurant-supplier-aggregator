require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

module RestaurantSupplierAggregator
  class Application < Rails::Application
    config.load_defaults 7.1

    # Autoload lib directory
    config.autoload_lib(ignore: %w[assets tasks])

    # Set timezone
    config.time_zone = "Eastern Time (US & Canada)"

    # Configure generators
    config.generators do |g|
      g.test_framework :rspec
      g.fixture_replacement :factory_bot, dir: "spec/factories"
      g.stylesheets false
      g.javascripts false
      g.helper false
    end

    # Active Job configuration
    config.active_job.queue_adapter = :solid_queue

    # Action Cable configuration
    config.action_cable.mount_path = "/cable"
  end
end
