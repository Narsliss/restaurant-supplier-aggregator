# frozen_string_literal: true

# Triggers a background refresh of API-fetched delivery dates (Sysco today)
# whenever cached values look stale. Included by controllers that render
# delivery-date-aware UI — the order builder and the review page.
#
# The goal is that chefs never have to manually refresh or remember to
# re-enter credentials when a supplier rep changes their delivery days.
# If they simply open the order UI, we kick off a silent refetch; the next
# page load reflects whatever the supplier now returns.
#
# See FetchSyscoDeliveryDatesJob for the worker behavior (concurrency limit,
# freshness double-check, and graceful no-op when values are already fresh).
module DeliveryDatesRefresher
  extend ActiveSupport::Concern

  # Cached dates older than this are considered stale enough to refetch.
  # Matches FetchSyscoDeliveryDatesJob::FRESHNESS_WINDOW — keep in sync.
  DELIVERY_DATES_FRESHNESS_WINDOW = 4.hours

  private

  # Accepts any iterable/relation of SupplierCredential records. Enqueues a
  # best-effort refresh for those whose supplier exposes a delivery-days API
  # and whose cached dates are stale or missing. No-ops for everyone else.
  def refresh_stale_delivery_dates!(credentials)
    credentials.each do |cred|
      next unless cred.supplier.api_delivery_dates?
      next if cred.delivery_dates_fetched_at.present? &&
              cred.delivery_dates_fetched_at >= DELIVERY_DATES_FRESHNESS_WINDOW.ago

      FetchSyscoDeliveryDatesJob.perform_later(cred.id)
    end
  end
end
