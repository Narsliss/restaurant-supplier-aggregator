# Solid Queue 0.9.0 keeps finished job rows forever unless something clears
# them — the gem ships clear_finished_in_batches but nothing calls it on a
# schedule. Because the queue lives IN Postgres (Solid Stack, no Redis), those
# rows accumulate on the DB volume (they filled it to 81% once). This runs the
# cleaner nightly; finished_before defaults to SolidQueue.clear_finished_jobs_after
# (1 day). FK on_delete: :cascade means associated executions (incl. recurring)
# go with each cleared job.
class ClearFinishedJobsJob < ApplicationJob
  queue_as :low

  def perform
    before = SolidQueue::Job.finished.count
    SolidQueue::Job.clear_finished_in_batches
    after = SolidQueue::Job.finished.count
    Rails.logger.info "[ClearFinishedJobs] cleared #{before - after} finished jobs (#{after} retained, cutoff #{SolidQueue.clear_finished_jobs_after.inspect})"
  end
end
