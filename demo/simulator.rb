# frozen_string_literal: true

module DemoMode
  # What each supplier job would have written had it run and succeeded,
  # without the supplier: a login that works, an import with nothing new,
  # prices that match, an order the supplier accepted. Only rows in the demo's
  # own database change. Arguments are the job's own perform arguments.
  module Simulator
    # Seconds before the outcome lands, so the screens show their normal
    # "Validating… / Importing… / Checking prices…" states for a moment.
    DELAY = {
      'ValidateCredentialsJob' => 2,
      'SyscoCombinedImportJob' => 3,
      'ImportSupplierProductsJob' => 3,
      'ImportSupplierListsJob' => 3,
      'PriceVerificationJob' => 2,
      'VerifyItemPriceJob' => 1,
      'PlaceOrderJob' => 3
    }.freeze

    # Supplier jobs with no visible outcome: never run, nothing to write.
    NO_OUTCOME = %w[
      AutoLinkSupplierRestaurantsJob ChefsWarehouseCatalogPricingJob DeepCatalogImportJob
      MirrorProductImageJob ScrapeSupplierJob SyscoMarketplaceRemovalJob
      RefreshAllSessionsJob StaggeredSupplierImportJob StaggeredDeepImportJob
      SyncAllListsJob UsFoodsExceptionSweepJob
    ].freeze

    HANDLERS = {
      'ValidateCredentialsJob' => :validate_credentials,
      'RefreshSessionJob' => :refresh_session,
      'ImportSupplierProductsJob' => :import_products,
      'ImportSupplierListsJob' => :import_lists,
      'SyscoCombinedImportJob' => :sysco_combined_import,
      'FetchSyscoDeliveryDatesJob' => :fetch_delivery_dates,
      'PriceVerificationJob' => :verify_prices,
      'VerifyItemPriceJob' => :verify_item_price,
      'PlaceOrderJob' => :place_order,
      'CheckOrderExceptionsJob' => :check_order_exceptions
    }.freeze

    def self.handles?(job_class_name)
      HANDLERS.key?(job_class_name) || NO_OUTCOME.include?(job_class_name)
    end

    def self.delay_for(job_class_name)
      DELAY.fetch(job_class_name, 1)
    end

    def self.run(job_class_name, arguments)
      handler = HANDLERS[job_class_name]
      return Rails.logger.info("[DemoMode] #{job_class_name} simulated (no outcome)") unless handler

      Rails.logger.info "[DemoMode] #{job_class_name}#{arguments.inspect} simulated"
      send(handler, *arguments)
    end

    # ── Supplier logins ──────────────────────────────────────────────────

    def self.validate_credentials(credential_id, *)
      cred = SupplierCredential.find_by(id: credential_id) or return
      Heal.scrub_secrets(cred)
      cred.mark_active!
      cred.update_columns(importing: true, import_status_text: 'Importing order guides...')
      if cred.supplier&.code == 'sysco'
        SyscoCombinedImportJob.perform_later(cred.id)
      else
        ImportSupplierListsJob.perform_later(cred.id)
        FetchSyscoDeliveryDatesJob.perform_later(cred.id, force: true) if cred.supplier&.api_delivery_dates?
      end
    end

    def self.refresh_session(credential_id = nil, *)
      cred = SupplierCredential.find_by(id: credential_id) or return
      cred.update_columns(status: 'active', last_login_at: Time.current, last_error: nil, refresh_failures: 0)
    end

    def self.import_products(supplier_id, credential_id = nil, *)
      SupplierProduct.where(supplier_id: supplier_id).update_all(last_scraped_at: Time.current)
      finish_import(credential_id) if credential_id.is_a?(Integer)
    end

    def self.import_lists(credential_id, *)
      finish_import(credential_id)
    end

    def self.sysco_combined_import(credential_id, *)
      cred = SupplierCredential.find_by(id: credential_id) or return
      cred.mark_active! unless cred.active?
      SupplierProduct.where(supplier_id: cred.supplier_id).update_all(last_scraped_at: Time.current)
      finish_import(cred.id)
      fetch_delivery_dates(cred.id)
    end

    def self.finish_import(credential_id)
      SupplierCredential.where(id: credential_id).update_all(
        importing: false, last_import_at: Time.current,
        import_progress: 0, import_total: 0, import_status_text: nil
      )
    end

    # Sysco/Performance publish their delivery days: the next two weeks, no Sundays.
    def self.fetch_delivery_dates(credential_id, *)
      SupplierCredential.where(id: credential_id).update_all(
        available_delivery_dates: delivery_dates, delivery_dates_error: nil,
        delivery_dates_fetched_at: Time.current
      )
    end

    def self.delivery_dates(from: Date.current)
      (1..14).map { |n| from + n }.reject(&:sunday?).map(&:iso8601)
    end

    # ── Orders ───────────────────────────────────────────────────────────

    # As a verification that found every price unchanged (PriceVerificationJob,
    # "verified" branch): each line verified at its own price, saved as a draft.
    def self.verify_prices(order_id, *)
      order = Order.find_by(id: order_id) or return
      return unless order.verifying?

      order.order_items.each { |item| item.update!(verified_price: item.unit_price) }
      total = order.order_items.reload.sum { |item| item.unit_price.to_d * item.quantity }
      order.mark_verified!(verified_total: total)
      order.mark_as_draft!
    end

    def self.verify_item_price(order_item_id, *)
      item = OrderItem.find_by(id: order_item_id) or return
      item.update!(verified_price: item.unit_price)
    end

    # As OrderPlacementService's success branch, with a demo confirmation
    # number and no supplier changes to report.
    def self.place_order(order_id, *)
      order = Order.find_by(id: order_id) or return
      return unless order.status == 'processing'

      attrs = {
        status: 'submitted',
        confirmation_number: "DEMO-#{Time.current.strftime('%Y%m%d')}-#{order.id}",
        total_amount: order.calculated_subtotal,
        submitted_at: Time.current,
        supplier_exceptions: [],
        exceptions_checked_at: Time.current
      }
      attrs[:submit_sent_at] = Time.current if Order.respond_to?(:submit_marker?) && Order.submit_marker?
      order.update!(attrs)
      order.order_items.update_all(status: 'added')
    end

    def self.check_order_exceptions(order_id, *)
      Order.where(id: order_id, exceptions_checked_at: nil)
           .update_all(supplier_exceptions: [], exceptions_checked_at: Time.current)
    end
  end
end
