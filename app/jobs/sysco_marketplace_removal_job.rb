# Runs Suppliers::SyscoMarketplaceRemoval on the worker (classifying the whole
# Sysco catalog takes a couple thousand search calls). Enqueued by hand:
#   SyscoMarketplaceRemovalJob.perform_later(credential_id, dry_run: true)
# The report is logged as one "[SyscoMarketplaceRemoval] report" line.
class SyscoMarketplaceRemovalJob < ApplicationJob
  queue_as :low
  limits_concurrency to: 1, key: ->(*) { 'sysco_marketplace_removal' }, duration: 2.hours

  def perform(credential_id, dry_run: true)
    credential = SupplierCredential.find(credential_id)
    report = Suppliers::SyscoMarketplaceRemoval.new(credential, dry_run: dry_run).call
    Rails.logger.info "[SyscoMarketplaceRemoval] report #{report.to_json}"
    report
  end
end
