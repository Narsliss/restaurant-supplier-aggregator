# Syncs all supplier lists/order guides on a recurring schedule.
# Enqueues individual ImportSupplierListsJob for each credential,
# staggered to avoid overwhelming supplier sites.
#
# Includes expired password-based credentials (CW, WCW) since they can
# auto-login without user interaction. Expired 2FA suppliers are skipped
# because they would trigger unwanted MFA prompts in a background job.
class SyncAllListsJob < ApplicationJob
  queue_as :scraping

  def perform
    credentials = SupplierCredential.where(status: %w[active expired]).includes(:supplier)

    # Filter: expired credentials only proceed if their supplier uses password auth
    syncable = credentials.select do |cred|
      cred.active? || cred.supplier.password_auth?
    end

    expired_count = syncable.count(&:expired?)
    Rails.logger.info "[SyncAllLists] Enqueuing list sync for #{syncable.size} credentials " \
                      "(#{expired_count} expired password-based included)"

    syncable.each_with_index do |credential, index|
      # Stagger jobs 30 seconds apart to avoid hitting suppliers simultaneously
      ImportSupplierListsJob.set(wait: (index * 30).seconds).perform_later(credential.id)
    end
  end
end
