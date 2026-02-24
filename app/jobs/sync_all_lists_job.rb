# Syncs supplier lists/order guides once daily on a per-organization basis.
# Picks ONE credential per supplier per org — preferring owner, then manager,
# then any member. This ensures full supplier coverage even when the owner
# hasn't added credentials for every supplier.
#
# Includes expired password-based credentials (CW, WCW) since they can
# auto-login without user interaction. Expired 2FA suppliers are skipped
# because they would trigger unwanted MFA prompts in a background job.
class SyncAllListsJob < ApplicationJob
  queue_as :scraping

  ROLE_PRIORITY = %w[owner manager member].freeze

  def perform
    credentials = one_credential_per_supplier_per_org

    syncable = credentials.select do |cred|
      cred.active? || cred.supplier.password_auth?
    end

    org_count = syncable.map(&:organization_id).uniq.size
    Rails.logger.info "[SyncAllLists] Enqueuing list sync for #{syncable.size} credentials " \
                      "across #{org_count} organization(s)"

    syncable.each_with_index do |credential, index|
      # Stagger jobs 30 seconds apart to avoid hitting suppliers simultaneously
      ImportSupplierListsJob.set(wait: (index * 30).seconds).perform_later(credential.id)
    end
  end

  private

  # For each organization, pick the single best credential per supplier.
  # Priority: active over expired, then owner > manager > member.
  def one_credential_per_supplier_per_org
    Organization.active.flat_map do |org|
      role_map = org.memberships.where(active: true).index_by(&:user_id)

      org.supplier_credentials
         .where(status: %w[active expired])
         .includes(:supplier)
         .group_by(&:supplier_id)
         .map do |_supplier_id, creds|
           best_credential(creds, role_map)
         end
    end
  end

  # Pick the best credential: active beats expired, then highest role wins
  def best_credential(creds, role_map)
    creds.min_by do |cred|
      status_rank = cred.active? ? 0 : 1
      role = role_map[cred.user_id]&.role || 'member'
      role_rank = ROLE_PRIORITY.index(role) || ROLE_PRIORITY.size
      [status_rank, role_rank]
    end
  end
end
