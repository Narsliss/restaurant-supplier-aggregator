# frozen_string_literal: true

class RefreshAllSessionsJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info '[RefreshAllSessionsJob] Queuing session refreshes for stale credentials'

    credentials = SupplierCredential.active.needs_refresh
    count = credentials.count

    if count.zero?
      Rails.logger.info '[RefreshAllSessionsJob] All active sessions are fresh — nothing to refresh'
      return
    end

    Rails.logger.info "[RefreshAllSessionsJob] Found #{count} credential(s) needing refresh"
    Authentication::SessionManager.refresh_all_sessions
  end
end
