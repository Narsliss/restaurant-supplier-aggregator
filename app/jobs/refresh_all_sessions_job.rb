# frozen_string_literal: true

class RefreshAllSessionsJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info '[RefreshAllSessionsJob] Queuing session refreshes for stale credentials'

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
