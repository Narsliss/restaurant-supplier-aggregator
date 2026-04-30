RSpec.configure do |config|
  config.before(:each) do
    # Inline-execute jobs by default unless a test opts into queuing with
    # `perform_enqueued_jobs` or sets a different adapter.
    ActiveJob::Base.queue_adapter = :test
  end
end
