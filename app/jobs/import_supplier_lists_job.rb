# Imports supplier lists/order guides for a single credential.
# Can be triggered manually (user clicks "Sync Lists") or by SyncAllListsJob.
class ImportSupplierListsJob < ApplicationJob
  queue_as :scraping

  # Prevent duplicate imports for the same credential
  limits_concurrency to: 1, key: ->(credential_id) { "import_lists_#{credential_id}" }

  def perform(credential_id)
    credential = SupplierCredential.find_by(id: credential_id)

    # Allow active credentials and expired password-based suppliers (CW, WCW)
    # which can auto-login. Skip expired 2FA suppliers (would trigger unwanted MFA).
    return unless credential&.active? ||
                  (credential&.expired? && credential.supplier.password_auth?)

    Rails.logger.info "[ImportListsJob] Starting for credential #{credential_id} (#{credential.supplier.name})"

    # Mark all existing lists as syncing immediately so the UI shows progress
    credential.supplier_lists.where.not(sync_status: 'syncing').update_all(sync_status: 'syncing')

    service = ImportSupplierListsService.new(credential)
    result = service.call

    Rails.logger.info "[ImportListsJob] Complete for credential #{credential_id}: #{result}"
  rescue StandardError => e
    Rails.logger.error "[ImportListsJob] Failed for credential #{credential_id}: #{e.class}: #{e.message}"
    # Mark any still-syncing lists as failed so the UI doesn't show a stale spinner
    credential&.supplier_lists&.where(sync_status: 'syncing')&.update_all(
      sync_status: 'failed', sync_error: "#{e.class}: #{e.message}"
    )
    raise # Let Solid Queue handle retries
  ensure
    # Clear the importing flag so the Stimulus UI transitions from
    # "Importing order guides..." to the success state.
    if credential&.persisted? && credential.importing?
      credential.update_columns(importing: false, import_status_text: nil)
    end
  end
end
