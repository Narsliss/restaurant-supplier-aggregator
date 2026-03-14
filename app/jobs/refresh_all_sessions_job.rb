# frozen_string_literal: true

class RefreshAllSessionsJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info '[RefreshAllSessionsJob] Queuing session refreshes for stale credentials'

    # Sysco session restore saves cookies + localStorage + sessionStorage.
    # It may or may not survive browser restarts — we try it and log the result.
    # If it fails, no harm done: the daily SyscoCombinedImportJob will do a fresh login.
    credentials = SupplierCredential.where(status: %w[active expired]).needs_refresh
    count = credentials.count

    if count.zero?
      Rails.logger.info '[RefreshAllSessionsJob] All sessions are fresh — nothing to refresh'
      return
    end

    Rails.logger.info "[RefreshAllSessionsJob] Found #{count} credential(s) needing refresh"
    credentials.find_each do |credential|
      RefreshSessionJob.perform_later(credential.id)
    end
  end
end
