# frozen_string_literal: true

# The sales demo's offline supplier layer. Loaded only by
# config/initializers/demo_mode.rb when DEMO_MODE=true; this folder sits
# outside app/ and lib/ so Rails never autoloads or eager-loads it.
#
# On the demo:
#   - no outbound connection leaves the server (NetworkWall) and no email is sent
#   - jobs run in the web process (there is no worker): database-only jobs for
#     real, supplier jobs as simulated outcomes (JobRunner, Simulator)
#   - an active login always counts as connected (Overrides)
#   - whatever the missing worker left stuck is freed, once a day (Heal)
#
# Every patch also checks DemoMode.enabled? at call time, so with the switch
# off a patched method behaves exactly as the original.
module DemoMode
  def self.enabled?
    ENV['DEMO_MODE'] == 'true'
  end

  def self.install!(app)
    require_relative 'network_wall'
    require_relative 'simulator'
    require_relative 'job_runner'
    require_relative 'overrides'
    require_relative 'heal'

    NetworkWall.install!

    ActiveSupport.on_load(:action_mailer) { self.perform_deliveries = false }

    # Registered after Active Job's own config hook, so this adapter wins.
    ActiveSupport.on_load(:active_job) { self.queue_adapter = DemoMode::JobRunner.new }

    app.config.to_prepare { DemoMode::Overrides.install! }

    # No log line here: with RAILS_LOG_TO_STDOUT it would land in the output
    # bin/start and bin/docker-entrypoint capture from `rails runner` (user
    # and table counts), and an empty database would no longer read as 0.
    app.config.middleware.use DemoMode::Heal::Middleware
  end
end
