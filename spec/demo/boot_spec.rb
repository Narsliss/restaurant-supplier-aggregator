# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# Boots the app in a separate process as production does (RAILS_ENV=production,
# everything eager-loaded) and reports what of the demo layer is present.
RSpec.describe 'Demo mode at boot' do
  report_script = <<~RUBY
    puts({
      eager_load: Rails.application.config.eager_load,
      demo_loaded: !defined?(DemoMode).nil?,
      queue_adapter: ActiveJob::Base.queue_adapter.class.name,
      http_patched: Net::HTTP.ancestors.map(&:to_s).grep(/DemoMode/).any?,
      credential_patched: SupplierCredential.ancestors.map(&:to_s).grep(/DemoMode/).any?,
      demo_middleware: Rails.application.middleware.map(&:inspect).grep(/DemoMode/).any?,
      mail_delivery: ActionMailer::Base.perform_deliveries
    }.to_json)
  RUBY

  define_method(:report_script) { report_script }

  def boot_report(demo_mode:)
    env = {
      'RAILS_ENV' => 'production',
      'SECRET_KEY_BASE_DUMMY' => '1', # skips the boot-time supplier seeding write
      'DATABASE_URL' => test_database_url,
      'DEMO_MODE' => demo_mode
    }
    out, status = Open3.capture2e(env, 'bin/rails', 'runner', report_script, chdir: Rails.root.to_s)
    expect(status).to be_success, out
    JSON.parse(out.lines.reverse.find { |l| l.start_with?('{') })
  end

  def test_database_url
    return ENV['DATABASE_URL'] if ENV['DATABASE_URL'].present?

    c = ActiveRecord::Base.connection_db_config.configuration_hash
    auth = c[:username] ? "#{c[:username]}#{":#{c[:password]}" if c[:password]}@" : ''
    "postgres://#{auth}#{c[:host]}#{":#{c[:port]}" if c[:port]}/#{c[:database]}"
  end

  it 'loads and changes nothing without DEMO_MODE (production behaviour unchanged)' do
    report = boot_report(demo_mode: nil)

    expect(report).to eq(
      'eager_load' => true,
      'demo_loaded' => false,
      'queue_adapter' => 'ActiveJob::QueueAdapters::SolidQueueAdapter',
      'http_patched' => false,
      'credential_patched' => false,
      'demo_middleware' => false,
      'mail_delivery' => true
    )
  end

  it 'installs the offline layer with DEMO_MODE=true' do
    report = boot_report(demo_mode: 'true')

    expect(report).to include(
      'demo_loaded' => true,
      'queue_adapter' => 'DemoMode::JobRunner',
      'http_patched' => true,
      'credential_patched' => true,
      'demo_middleware' => true,
      'mail_delivery' => false
    )
  end
end
