# Imports supplier lists/order guides for a single credential.
# Can be triggered manually (user clicks "Sync Lists") or by SyncAllListsJob.
#
# Freshness check: if this supplier+org already has lists synced within
# FRESHNESS_THRESHOLD, skip the scrape to avoid redundant browser sessions.
# Pass force: true to bypass (used when user explicitly clicks "Sync" on a list).
class ImportSupplierListsJob < ApplicationJob
  # Own queue and worker (config/queue.yml): short supplier API calls that
  # shouldn't wait behind catalog imports — at 8 AM, or when a chef presses Sync.
  queue_as :list_sync

  # If all lists for this supplier+org were synced within this window, skip.
  # 4 hours is short enough that the daily cron (24h cadence) always runs,
  # but long enough to prevent redundant syncs from overlapping triggers
  # (Sync All button, credential setup, 2FA completion).
  FRESHNESS_THRESHOLD = 4.hours

  # Prevent duplicate imports for the same credential
  limits_concurrency to: 1, key: ->(credential_id, **) { "import_lists_#{credential_id}" }

  # refresh_seeded: chef pressed "Refresh Recent Orders" — after the live
  # scrape lands, create/re-mirror their seeded order lists so the button's
  # promise completes without a second press.
  #
  # delivery_dates: Sysco at 8 AM (SyncAllListsJob) — refresh the account's
  # delivery dates once the guide sync is done, reusing the session it checked.
  def perform(credential_id, force: false, refresh_seeded: false, delivery_dates: false)
    @refresh_seeded = refresh_seeded
    credential = SupplierCredential.find_by(id: credential_id)

    # Allow active credentials and expired password-based suppliers (CW, WCW)
    # which can auto-login. Skip expired 2FA suppliers (would trigger unwanted MFA).
    return unless credential&.active? ||
                  (credential&.expired? && credential.supplier.password_auth?)

    # Skip if this login's own lists are already fresh (unless forced).
    # This prevents redundant scraping when several people at one restaurant
    # have logins for the same supplier, or when triggers fire in quick
    # succession. Another restaurant's fresh lists say nothing about these.
    unless force
      org = credential.organization || credential.user.current_organization
      fresh_lists = lists_this_login_syncs(credential, org)
                                .where(sync_status: 'synced')
                                .where('last_synced_at > ?', FRESHNESS_THRESHOLD.ago)

      if fresh_lists.exists?
        Rails.logger.info "[ImportListsJob] Skipping credential #{credential_id} (#{credential.supplier.name}) — " \
                          "#{fresh_lists.count} list(s) already synced within #{FRESHNESS_THRESHOLD.inspect}"
        FetchSyscoDeliveryDatesJob.perform_later(credential.id, force: true) if delivery_dates
        return
      end
    end

    Rails.logger.info "[ImportListsJob] Starting for credential #{credential_id} (#{credential.supplier.name})#{' (forced)' if force}"

    # Create a scraping log so the admin dashboard health metrics include list syncs
    @scraping_log = ScrapingLog.create!(
      supplier: credential.supplier,
      supplier_credential: credential,
      status: 'running',
      started_at: Time.current
    )

    # Mark this login's lists as syncing immediately so the UI shows progress
    org ||= credential.organization || credential.user.current_organization
    lists_this_login_syncs(credential, org)
      .where.not(sync_status: 'syncing')
      .update_all(sync_status: 'syncing')

    service = ImportSupplierListsService.new(credential)
    result = service.call

    if @refresh_seeded && result[:lists_synced].to_i > 0
      refresh_result = SeedOrderListsService.new(credential).refresh
      Rails.logger.info "[ImportListsJob] Post-scrape seeded-list refresh for credential #{credential_id}: #{refresh_result.inspect}"
    end

    Rails.logger.info "[ImportListsJob] Complete for credential #{credential_id}: #{result}"

    @scraping_log.mark_completed!(
      product_count: result.is_a?(Hash) ? result[:imported] : nil,
      products_updated: result.is_a?(Hash) ? result[:updated] : nil
    )
    # The service catches its own errors, so a supplier refusing us (HTTP
    # 429/403) would otherwise vanish. The 9:15 report counts these.
    if result.is_a?(Hash) && result[:errors].present?
      @scraping_log.update!(metadata: { 'errors' => result[:errors].first(5) })
    end
    FetchSyscoDeliveryDatesJob.perform_later(credential.id, force: true) if delivery_dates
  rescue StandardError => e
    Rails.logger.error "[ImportListsJob] Failed for credential #{credential_id}: #{e.class}: #{e.message}"
    @scraping_log&.mark_failed!("#{e.class}: #{e.message}")

    # Mark any still-syncing lists as failed so the UI doesn't show a stale spinner
    org ||= credential&.organization || credential&.user&.current_organization
    if credential && org
      lists_this_login_syncs(credential, org)
        .where(sync_status: 'syncing')
        .update_all(sync_status: 'failed', sync_error: "#{e.class}: #{e.message}")
    end
    raise # Let Solid Queue handle retries
  ensure
    # Clear the importing flag so the Stimulus UI transitions from
    # "Importing order guides..." to the success state.
    if credential&.persisted? && credential.importing?
      credential.update_columns(importing: false, import_status_text: nil)
    end
  end

  private

  # The lists this login's sync can reach: its own restaurant, or each
  # restaurant matched on a multi-restaurant login. Marking, skipping and
  # failing must stay inside these. They used to cover every list of the
  # supplier in the organization, so one restaurant's sync left the other
  # restaurants' lists "syncing" for good (35 of Alfio's lists, Oct 2026;
  # docs/fix-stuck-syncing-lists.md).
  def lists_this_login_syncs(credential, org)
    locations = credential.multi_restaurant? ? credential.restaurants.pluck(:location_id) : [credential.location_id]
    SupplierList.where(supplier: credential.supplier, organization: org, location_id: locations)
  end
end
