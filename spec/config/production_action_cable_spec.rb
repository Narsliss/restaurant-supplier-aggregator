require 'rails_helper'

# docs/fix-live-updates-on-enplacepro.md: a pinned Action Cable host stopped
# every live update (menu planner replies, 2FA code prompts) on enplacepro.app.
RSpec.describe 'config/environments/production.rb Action Cable settings' do
  # Records `config.x.y = value` calls so the production block can run without
  # touching the test app's real configuration.
  recorder = Class.new do
    def initialize
      @values = {}
    end

    def [](key)
      @values[key]
    end

    def method_missing(name, *args)
      if name.end_with?('=')
        @values[name.to_s.chomp('=').to_sym] = args.first
      else
        @values[name] ||= self.class.new
      end
    end

    def respond_to_missing?(*)
      true
    end
  end

  let(:cable) do
    fake_app = Struct.new(:config).new(recorder.new)
    allow(Rails.application).to receive(:configure) { |&block| fake_app.instance_eval(&block) }
    load Rails.root.join('config/environments/production.rb').to_s
    fake_app.config.action_cable
  end

  def allowed?(origin)
    Array(cable[:allowed_request_origins]).any? { |allowed| allowed === origin }
  end

  it 'does not pin the socket to a host, so browsers connect to the site they are on' do
    expect(cable[:url]).to be_nil
  end

  it 'accepts connections from both enplacepro.app hostnames' do
    expect(allowed?('https://enplacepro.app')).to be(true)
    expect(allowed?('https://www.enplacepro.app')).to be(true)
  end

  it 'no longer accepts connections from Railway-hosted sites' do
    expect(allowed?('https://pretty-friendship-production-7e4d.up.railway.app')).to be(false)
    expect(allowed?('https://someone-else.up.railway.app')).to be(false)
  end
end
