# Imports supplier lists/order guides for a single credential.
# Can be triggered manually (user clicks "Sync Lists") or by SyncAllListsJob.
#
# Freshness check: if this supplier+org already has lists synced within
# FRESHNESS_THRESHOLD, skip the scrape to avoid redundant browser sessions.
# Pass force: true to bypass (used when user explicitly clicks "Sync" on a list).
class ImportSupplierListsJob < ApplicationJob
  queue_as :scraping

  # If all lists for this supplier+org were synced within this window, skip.
  # 4 hours is short enough that the daily cron (24h cadence) always runs,
  # but long enough to prevent redundant syncs from overlapping triggers
  # (Sync All button, credential setup, 2FA completion).
  FRESHNESS_THRESHOLD = 4.hours

  # Prevent duplicate imports for the same credential
  limits_concurrency to: 1, key: ->(credential_id, **) { "import_lists_#{credential_id}" }

  def perform(credential_id, force: false)
    credential = SupplierCredential.find_by(id: credential_id)

    # Allow active credentials and expired password-based suppliers (CW, WCW)
    # which can auto-login. Skip expired 2FA suppliers (would trigger unwanted MFA).
    return unless credential&.active? ||
                  (credential&.expired? && credential.supplier.password_auth?)

    # Skip if this supplier+org already has fresh lists (unless forced).
    # This prevents redundant scraping when multiple users have credentials
    # for the same supplier, or when multiple triggers fire in quick succession.
    unless force
      org = credential.organization || credential.user.current_organization
      fresh_lists = SupplierList.where(supplier: credential.supplier, organization: org)
                                .where(sync_status: 'synced')
                                .where('last_synced_at > ?', FRESHNESS_THRESHOLD.ago)

      if fresh_lists.exists?
        Rails.logger.info "[ImportListsJob] Skipping credential #{credential_id} (#{credential.supplier.name}) — " \
                          "#{fresh_lists.count} list(s) already synced within #{FRESHNESS_THRESHOLD.inspect}"
        return
      end
    end

    Rails.logger.info "[ImportListsJob] Starting for credential #{credential_id} (#{credential.supplier.name})#{' (forced)' if force}"

    # Mark all existing lists as syncing immediately so the UI shows progress
    org ||= credential.organization || credential.user.current_organization
    SupplierList.where(supplier: credential.supplier, organization: org)
                .where.not(sync_status: 'syncing')
                .update_all(sync_status: 'syncing')

    service = ImportSupplierListsService.new(credential)
    result = service.call

    Rails.logger.info "[ImportListsJob] Complete for credential #{credential_id}: #{result}"
  rescue StandardError => e
    Rails.logger.error "[ImportListsJob] Failed for credential #{credential_id}: #{e.class}: #{e.message}"
    # Mark any still-syncing lists as failed so the UI doesn't show a stale spinner
    org ||= credential&.organization || credential&.user&.current_organization
    if credential && org
      SupplierList.where(supplier: credential.supplier, organization: org)
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
end
