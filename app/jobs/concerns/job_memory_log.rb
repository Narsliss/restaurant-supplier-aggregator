# Which jobs make the worker's memory climb (Oct 2026). The worker settles
# around 1.3-1.4 GB and never comes back down: Ruby keeps a process at the peak
# of the heaviest job it has run. When one job grows its process by GROWTH_MB
# or more, this logs one line and keeps a row for the day in the cache (it
# lives in Postgres, so it survives a deploy; Railway's logs are per
# deployment). Quiet otherwise. docs/job-memory-log.md
#
# The size is the whole process's resident memory, so a job that ran alongside
# others in the same process can be charged for their growth too: each line
# says how many jobs were running in the process at the time.
module JobMemoryLog
  extend ActiveSupport::Concern

  GROWTH_MB = 25
  KEPT_PER_DAY = 300
  KEPT_FOR = 14.days

  IN_FLIGHT = Concurrent::AtomicFixnum.new(0)

  included do
    around_perform do |job, block|
      before = JobMemoryLog.rss_mb
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      IN_FLIGHT.increment
      begin
        block.call
      ensure
        alongside = IN_FLIGHT.decrement
        JobMemoryLog.note(job, before, started, alongside)
      end
    end
  end

  # Resident memory of this process in MB, or nil where /proc doesn't exist
  # (macOS in development and tests).
  def self.rss_mb
    File.foreach('/proc/self/status') do |line|
      return line.split[1].to_i / 1024.0 if line.start_with?('VmRSS:')
    end
    nil
  rescue StandardError
    nil
  end

  def self.note(job, before, started, alongside)
    return unless before

    after = rss_mb
    return unless after && after - before >= GROWTH_MB

    seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
    row = { 'at' => Time.current.iso8601, 'job' => job.class.name, 'queue' => job.queue_name,
            'before_mb' => before.round, 'after_mb' => after.round, 'seconds' => seconds,
            'alongside' => alongside, 'pid' => Process.pid }
    Rails.logger.info "[JobMemory] #{row['job']} (#{row['queue']}) grew its process " \
                      "#{row['before_mb']}->#{row['after_mb']} MB (+#{(after - before).round}) in #{seconds}s, " \
                      "#{alongside} other job(s) running in the process, pid #{row['pid']}"

    key = "job_memory:#{Date.current.iso8601}"
    rows = Rails.cache.read(key) || []
    Rails.cache.write(key, (rows << row).last(KEPT_PER_DAY), expires_in: KEPT_FOR)
  rescue StandardError => e
    Rails.logger.warn "[JobMemory] could not record: #{e.class}: #{e.message}"
  end
end
