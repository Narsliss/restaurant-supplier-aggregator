require 'vcr'

VCR.configure do |c|
  c.cassette_library_dir = Rails.root.join('spec/fixtures/vcr_cassettes')
  c.hook_into :webmock
  c.configure_rspec_metadata!
  c.allow_http_connections_when_no_cassette = false
  c.default_cassette_options = { record: :none }

  # Scrub anything that could leak credentials.
  c.filter_sensitive_data('<BEARER_TOKEN>') do |interaction|
    auth = interaction.request.headers['Authorization']&.first
    auth&.start_with?('Bearer ') ? auth.sub('Bearer ', '') : nil
  end
end
