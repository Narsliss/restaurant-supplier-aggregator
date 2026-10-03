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

      credential = Suppliers::OrderCredential.scope(@order, statuses: %w[active]).take
      return nil unless credential

      scraper = supplier.scraper_klass.new(credential)
      scraper.soft_refresh if scraper.respond_to?(:soft_refresh)

      # US Foods only shows an order to the restaurant it was placed for. It
      # also re-files the order under a new id once processed, so pass what
      # it takes to recognise it by delivery date + items.
      our_skus = @order.order_items.joins(:supplier_product).pluck('supplier_products.supplier_sku').map(&:to_s)
      remote = Suppliers::RestaurantSwitcher.new(credential, scraper).with_restaurant(@order.location_id) do
        scraper.fetch_submitted_order(@order.confirmation_number, delivery_date: @order.delivery_date, skus: our_skus)
      end
      return nil if remote.nil?

      # Only lines that are on our order (a matched order could carry extra
      # lines a chef added on US Foods' own site).
      exceptions = UsFoodsExceptionParser.parse(remote)
                                         .select { |e| e[:sku].nil? || our_skus.include?(e[:sku].to_s) }
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
