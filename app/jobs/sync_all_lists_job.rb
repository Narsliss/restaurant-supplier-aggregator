# Daily job to sync all supplier lists for all active credentials.
# Enqueues individual ImportSupplierListsJob for each credential,
# staggered to avoid overwhelming supplier sites.
class SyncAllListsJob < ApplicationJob
  queue_as :default

  def perform
    credentials = SupplierCredential.active.includes(:supplier)
    Rails.logger.info "[SyncAllLists] Enqueuing list sync for #{credentials.count} active credentials"

    credentials.find_each.with_index do |credential, index|
      # Stagger jobs 30 seconds apart to avoid hitting suppliers simultaneously
      ImportSupplierListsJob.set(wait: (index * 30).seconds).perform_later(credential.id)
    end
  end
end
