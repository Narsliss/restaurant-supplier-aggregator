require 'webmock/rspec'

# Disable all real HTTP. Tests must stub or use VCR cassettes for outbound calls.
# Localhost stays open so capybara/system specs and selenium driver work.
WebMock.disable_net_connect!(allow_localhost: true)
