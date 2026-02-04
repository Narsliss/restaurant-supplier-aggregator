class ImportSupplierProductsJob < ApplicationJob
  queue_as :scraping

  retry_on StandardError, wait: 5.minutes, attempts: 2
  discard_on ActiveRecord::RecordNotFound

  def perform(credential_id, search_terms = nil)
    credential = SupplierCredential.find(credential_id)

    unless credential.active? || credential.status == "pending"
      Rails.logger.warn "[ImportProductsJob] Credential ##{credential_id} status is '#{credential.status}', skipping import"
      return
    end

    credential.update!(importing: true)

    service = ImportSupplierProductsService.new(credential)
    results = service.import_catalog(search_terms: search_terms)

    Rails.logger.info "[ImportProductsJob] #{credential.supplier.name}: imported=#{results[:imported]}, updated=#{results[:updated]}, skipped=#{results[:skipped]}, errors=#{results[:errors].size}"
  ensure
    credential&.update_columns(importing: false, last_import_at: Time.current) if credential&.persisted?
  end
end
