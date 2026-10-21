# frozen_string_literal: true

require 'rails_helper'

# The test app boots without DEMO_MODE, so config/initializers/demo_mode.rb
# loads nothing. These specs load the demo layer themselves and install its
# patches; every patch checks DemoMode.enabled? at call time, so outside the
# 'demo mode on' examples the rest of the suite runs exactly as before.
%w[demo_mode network_wall simulator job_runner overrides heal].each do |file|
  require Rails.root.join("demo/#{file}").to_s
end
DemoMode::NetworkWall.install!
DemoMode::Overrides.install!

RSpec.shared_context 'demo mode on' do
  around do |example|
    previous = ENV.fetch('DEMO_MODE', nil)
    ENV['DEMO_MODE'] = 'true'
    example.run
  ensure
    previous.nil? ? ENV.delete('DEMO_MODE') : ENV['DEMO_MODE'] = previous
  end
end

# A `before`, not an `around`: spec/support/active_job.rb sets the :test
# adapter in a global before hook, which runs inside any around hook. Request
# specs also pin a test adapter on ActiveJob::Base (ActiveJob::TestHelper);
# that is lifted here, on Base only, and the helper puts it back for the
# next example. Never touch the job subclasses: an explicit nil on a subclass
# outlives the example and breaks every later spec's job matchers.
RSpec.shared_context 'demo jobs inline' do
  before do
    ActiveJob::Base.queue_adapter = DemoMode::JobRunner.new(inline: true)
    ActiveJob::Base.disable_test_adapter if ActiveJob::Base.respond_to?(:disable_test_adapter)
  end
end
