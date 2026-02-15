# frozen_string_literal: true

# Schedules staggered session refreshes to keep all user sessions alive
# Minimally intrusive - uses soft_refresh only, staggered across the 2-hour window
class SessionRefreshSchedulerJob < ApplicationJob
  queue_as :default

  # Run every 2 hours via recurring.yml
  # Staggers refreshes across all active credentials to avoid overwhelming supplier sites
  def perform
    Rails.logger.info '[SessionRefreshSchedulerJob] Starting session refresh cycle'

    # Get all active credentials that need refresh
    credentials_to_refresh = SupplierCredential
                             .active
                             .where('last_login_at < ? OR last_login_at IS NULL', 2.hours.ago)
                             .order(:updated_at)

    total_credentials = credentials_to_refresh.count

    if total_credentials == 0
      Rails.logger.info '[SessionRefreshSchedulerJob] No credentials need refresh'
      return
    end

    Rails.logger.info "[SessionRefreshSchedulerJob] Scheduling refresh for #{total_credentials} credentials"

    # Stagger refreshes over 90 minutes (leaving 30 min buffer before next 2-hour cycle)
    # This minimizes load on supplier sites
    stagger_interval = 90.minutes.to_f / total_credentials

    credentials_to_refresh.each_with_index do |credential, index|
      delay_seconds = (index * stagger_interval).to_i

      # Use perform_later with wait for staggered execution
      # Note: Solid Queue handles scheduled jobs with 'wait' parameter
      RefreshSessionJob.set(wait: delay_seconds.seconds).perform_later(credential.id)

      Rails.logger.debug "[SessionRefreshSchedulerJob] Scheduled refresh for #{credential.supplier.name} in #{delay_seconds}s"
    end

    Rails.logger.info "[SessionRefreshSchedulerJob] Scheduled #{total_credentials} session refreshes over 90 minutes"
  end
end
