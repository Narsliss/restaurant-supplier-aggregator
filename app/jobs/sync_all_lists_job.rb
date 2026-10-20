# Syncs supplier lists/order guides once daily on a per-organization basis.
# Picks ONE credential per supplier per org — preferring owner, then manager,
# then any member. This ensures full supplier coverage even when the owner
# hasn't added credentials for every supplier.
#
# Includes expired password-based credentials (CW, WCW) since they can
# auto-login without user interaction. Expired 2FA suppliers are skipped
# because they would trigger unwanted MFA prompts in a background job.
class SyncAllListsJob < ApplicationJob
  queue_as :list_sync

  ROLE_PRIORITY = %w[owner manager member].freeze

  # Gap between two logins of the SAME supplier. Suppliers run side by side,
  # so this is our per-supplier rate limit. It used to be one 30-second line
  # for every login of every supplier: at 250 restaurants the last guide would
  # start ~9 hours after 8 AM (docs/fix-morning-sync-at-scale.md).
  STAGGER = 30.seconds

  def perform
    credentials = one_credential_per_supplier_per_org

    syncable = credentials.select do |cred|
      cred.active? || cred.supplier.password_auth?
    end

    org_count = syncable.map(&:organization_id).uniq.size
    Rails.logger.info "[SyncAllLists] Enqueuing list sync for #{syncable.size} credentials " \
                      "across #{org_count} organization(s)"

    syncable.group_by(&:supplier_id).each_value do |creds|
      creds.each_with_index do |credential, index|
        # Sysco syncs only its guide here, like the others: the 6 AM run
        # imports its catalog once a day (this used to re-import all of it
        # for every Sysco login, ~20 min each). Its delivery dates are per
        # account, so the guide sync queues them when it finishes.
        options = credential.supplier.code == 'sysco' ? { delivery_dates: true } : {}
        ImportSupplierListsJob.set(wait: index * STAGGER).perform_later(credential.id, **options)
      end
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
