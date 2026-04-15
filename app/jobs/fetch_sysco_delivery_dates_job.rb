# frozen_string_literal: true

# Lightweight refresh of a single Sysco credential's available delivery dates.
#
# Called from the order builder and review pages when the stored
# `delivery_dates_fetched_at` is stale (older than ~4 hours) or missing.
# Keeps the displayed delivery dates in sync with Sysco without asking the
# chef to remember anything — if they open the order UI, we quietly
# re-fetch in the background.
#
# Uses the same `ensure_api_session!` path as SyscoCombinedImportJob, so the
# browser is only opened when the JWT is expired (rare — tokens live ~7 days).
# In the common case this is a pure HTTP GraphQL call.
class FetchSyscoDeliveryDatesJob < ApplicationJob
  queue_as :scraping

  # One refresh at a time per credential; dedupe overlapping enqueues from
  # concurrent order-builder / review page loads.
  limits_concurrency to: 1,
                     key: ->(credential_id, **_) { "sysco_delivery_dates_#{credential_id}" }

  retry_on StandardError, attempts: 2, wait: 30.seconds
  discard_on ActiveRecord::RecordNotFound

  # Skip if another request already refreshed within this window. Anything
  # newer than this is considered "fresh enough" for a user-triggered poke.
  FRESHNESS_WINDOW = 4.hours

  def perform(credential_id, force: false)
    credential = SupplierCredential.find(credential_id)
    supplier = credential.supplier

    unless supplier.code == 'sysco'
      Rails.logger.warn "[FetchSyscoDeliveryDates] Credential #{credential_id} is not a Sysco credential (#{supplier.code}), skipping"
      return
    end

    unless credential.active? || credential.status == 'pending'
      Rails.logger.info "[FetchSyscoDeliveryDates] Credential #{credential_id} status '#{credential.status}', skipping"
      return
    end

    # Belt-and-suspenders freshness check — even if the caller enqueued us,
    # another worker may have already refreshed. Avoid duplicate browser work.
    if !force && credential.delivery_dates_fetched_at.present? &&
       credential.delivery_dates_fetched_at > FRESHNESS_WINDOW.ago
      Rails.logger.info "[FetchSyscoDeliveryDates] Credential #{credential_id} already fresh " \
                        "(fetched #{time_ago_in_words(credential.delivery_dates_fetched_at)} ago), skipping"
      return
    end

    Rails.logger.info "[FetchSyscoDeliveryDates] Refreshing delivery dates for credential #{credential_id}"
    scraper = supplier.scraper_klass.new(credential)

    # ensure_api_session! is cheap when the JWT is still valid (pure HTTP).
    # Only opens a headless browser if the stored tokens have expired.
    scraper.send(:ensure_api_session!)

    available_dates = scraper.fetch_available_delivery_days(shipping_condition: 0)

    if available_dates.any?
      credential.update_columns(
        available_delivery_dates: available_dates,
        delivery_dates_fetched_at: Time.current
      )
      Rails.logger.info "[FetchSyscoDeliveryDates] Stored #{available_dates.size} dates for credential #{credential_id} " \
                        "(#{available_dates.first}..#{available_dates.last})"
    else
      # Don't stomp on previously-stored dates with an empty array — the API
      # may have transiently failed and we prefer stale data to none.
      Rails.logger.warn "[FetchSyscoDeliveryDates] getDeliveryDays returned no dates for credential #{credential_id}; " \
                        "leaving previous values intact"
    end
  rescue Scrapers::BaseScraper::AuthenticationError => e
    Rails.logger.warn "[FetchSyscoDeliveryDates] Auth failed for credential #{credential_id}: #{e.message}"
    # Don't mark_failed! here — this is a background poll, not a user action.
    # Credential validation jobs own the active/failed transitions.
  end

  private

  def time_ago_in_words(time)
    ActionController::Base.helpers.time_ago_in_words(time)
  end
end
