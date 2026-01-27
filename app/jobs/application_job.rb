class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  discard_on ActiveJob::DeserializationError

  # Log job execution
  around_perform do |job, block|
    Rails.logger.info "[#{job.class.name}] Starting job with args: #{job.arguments.inspect}"
    start_time = Time.current
    block.call
    elapsed = Time.current - start_time
    Rails.logger.info "[#{job.class.name}] Completed in #{elapsed.round(2)}s"
  rescue => e
    Rails.logger.error "[#{job.class.name}] Failed: #{e.class} - #{e.message}"
    raise
  end
end
