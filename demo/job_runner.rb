# frozen_string_literal: true

require 'concurrent'

module DemoMode
  # The demo's Active Job queue. The demo has no worker, so instead of queueing
  # for one that never comes, every job is decided here, in the web process:
  #
  #   LOCAL     jobs that only use our own database (matching, catalog search…)
  #             run for real on a small background thread pool
  #   supplier  jobs that would talk to a supplier never run; Simulator writes
  #             the outcome a successful run would have
  #   anything else (mail, alerts, sweeps, resets, jobs added later) is dropped
  #             and logged — unknown jobs fail closed
  class JobRunner
    LOCAL = %w[
      AiProductMatchJob IncrementalProductMatchJob SyncNewProductsJob
      CatalogSearchJob TeaserCatalogSearchJob BuildComparisonCandidatesJob
      CategorizeProductsJob BackfillProductCategoriesJob
      GenerateMenuPlanJob ParsePriceListJob
    ].freeze

    # Known jobs the demo deliberately never runs: mail and alerts (no email
    # leaves the demo), sweeps and resets that only make sense with a worker.
    # Any job on none of the lists is dropped too; spec/demo makes sure every
    # job in app/jobs has been looked at.
    DROPPED = %w[
      ActionMailer::MailDeliveryJob ClearFinishedJobsJob DemoResetJob DiscontinueStaleProductsJob
      Expire2faRequestsJob ExpireDraftsJob MatchHealthCheckJob MorningStockReportJob
      NotifyOffListOrderJob OrderFailureAlertJob StuckOrderAlertJob TwoFactorNotificationJob
    ].freeze

    # Never start a job before the request that queued it has committed.
    MIN_DELAY = 0.5

    # inline: run each job at once in the calling thread (specs only).
    def initialize(threads: 2, inline: false)
      @inline = inline
      @pool = Concurrent::ThreadPoolExecutor.new(min_threads: 0, max_threads: threads, max_queue: 0) unless inline
    end

    def self.kind_of(job_class_name)
      return :local if LOCAL.include?(job_class_name)
      return :supplier if Simulator.handles?(job_class_name)

      :dropped
    end

    def enqueue(job)
      schedule(job, 0)
    end

    def enqueue_at(job, timestamp)
      schedule(job, timestamp.to_f - Time.now.to_f)
    end

    private

    def schedule(job, delay)
      name = job.class.name
      kind = self.class.kind_of(name)

      if kind == :dropped
        Rails.logger.info "[DemoMode] Dropped #{name} (no worker on the demo)"
        return
      end

      payload = kind == :local ? job.serialize : job.arguments
      return perform(kind, name, payload) if @inline

      delay = [delay, 0].max + (kind == :supplier ? Simulator.delay_for(name) : 0)
      Concurrent::ScheduledTask.execute([delay, MIN_DELAY].max, executor: @pool) { perform(kind, name, payload) }
    end

    def perform(kind, name, payload)
      Rails.application.reloader.wrap do
        kind == :local ? ActiveJob::Base.execute(payload) : Simulator.run(name, payload)
      end
    rescue StandardError => e
      raise if @inline

      Rails.logger.error "[DemoMode] #{name} failed: #{e.class}: #{e.message}"
    end
  end
end
