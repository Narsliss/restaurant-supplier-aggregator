module Orders
  # Re-fetches a submitted order from the supplier and records any exceptions
  # (out of stock, substitutions, short-fills, price changes) on our Order so the
  # chef gets alerted. READ-ONLY against the supplier — never re-submits.
  #
  # US Foods only for now (its API exposes a clean exception model). Other
  # suppliers no-op until their fetch/parse is added.
  class SupplierExceptionChecker
    def initialize(order)
      @order = order
    end

    # Returns the normalized exceptions array (also persisted), or nil when we
    # couldn't check (unsupported supplier, no credential, fetch failed).
    def check!
      supplier = @order.supplier
      return nil unless supplier&.code == 'usfoods'
      return nil if @order.confirmation_number.blank?

      credential = @order.user.supplier_credentials.find_by(supplier: supplier, status: 'active')
      return nil unless credential

      scraper = supplier.scraper_klass.new(credential)
      scraper.soft_refresh if scraper.respond_to?(:soft_refresh)

      remote = scraper.fetch_submitted_order(@order.confirmation_number)
      return nil if remote.nil?

      exceptions = UsFoodsExceptionParser.parse(remote)
      enrich_names!(exceptions, supplier)
      @order.update!(supplier_exceptions: exceptions, exceptions_checked_at: Time.current)

      Rails.logger.info "[SupplierExceptionChecker] Order #{@order.id}: #{exceptions.size} exception(s)"
      exceptions
    rescue StandardError => e
      Rails.logger.warn "[SupplierExceptionChecker] Order #{@order.id}: #{e.class} #{e.message}"
      nil
    end

    private

    # Fill in human-readable product names from our catalog (USF line items
    # reference products by number, not name).
    def enrich_names!(exceptions, supplier)
      skus = exceptions.filter_map { |e| e[:sku] }.uniq
      return if skus.empty?

      names = SupplierProduct.where(supplier_id: supplier.id, supplier_sku: skus)
                             .pluck(:supplier_sku, :supplier_name).to_h
      exceptions.each { |e| e[:name] = names[e[:sku]] if e[:sku] }
    end
  end
end
