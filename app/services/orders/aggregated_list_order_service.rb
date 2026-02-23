module Orders
  class AggregatedListOrderService
    attr_reader :user, :aggregated_list, :quantities, :supplier_overrides, :location, :delivery_date

    def initialize(user:, aggregated_list:, quantities:, supplier_overrides: {}, location: nil, delivery_date: nil)
      @user = user
      @aggregated_list = aggregated_list
      @quantities = quantities.transform_keys(&:to_s).transform_values(&:to_i)
      @supplier_overrides = supplier_overrides.transform_keys(&:to_s).transform_values(&:to_i)
      @location = location
      @delivery_date = delivery_date
    end

    # Creates pending Order records grouped by cheapest supplier.
    # SAFETY: Only creates status: "pending" orders. Never calls submit!,
    # PlaceOrderJob, OrderPlacementService, or any scraper code.
    # Returns [orders_array, batch_id_string].
    def create_pending_orders!
      selected_items = build_selected_items
      return [[], nil] if selected_items.empty?

      by_supplier = selected_items.group_by { |item| item[:supplier_id] }

      batch_id = SecureRandom.uuid
      orders = []
      ActiveRecord::Base.transaction do
        by_supplier.each do |supplier_id, items|
          supplier = Supplier.find(supplier_id)

          order = user.orders.create!(
            supplier: supplier,
            location: location,
            status: "pending",
            delivery_date: delivery_date,
            notes: "Created from #{aggregated_list.name}",
            organization_id: user.current_organization&.id,
            batch_id: batch_id
          )

          # Bulk-insert order items (single INSERT instead of N individual queries)
          now = Time.current
          subtotal = 0
          order_savings = 0

          rows = items.map do |item|
            line_total = item[:unit_price] * item[:quantity]
            subtotal += line_total

            if item[:worst_price] && item[:worst_price] > item[:unit_price]
              order_savings += (item[:worst_price] - item[:unit_price]) * item[:quantity]
            end

            {
              order_id: order.id,
              supplier_product_id: item[:supplier_product_id],
              quantity: item[:quantity],
              unit_price: item[:unit_price],
              line_total: line_total,
              status: "pending",
              created_at: now,
              updated_at: now
            }
          end

          OrderItem.insert_all!(rows)
          order.update!(subtotal: subtotal, total_amount: subtotal, savings_amount: order_savings.round(2))
          orders << order
        end
      end

      [orders, batch_id]
    end

    private

    def build_selected_items
      selected = []

      product_matches = aggregated_list.product_matches
        .where.not(match_status: 'rejected')
        .includes(product_match_items: [:supplier, { supplier_list_item: :supplier_product }])

      product_matches.each do |pm|
        qty = quantities[pm.id.to_s]
        next if qty.nil? || qty <= 0

        # Compute prices once per match (avoid 3x recalculation via cheapest/most_expensive)
        prices = pm.prices_by_supplier
        in_stock_prices = prices.select { |p| p[:price].present? && p[:in_stock] }

        override_supplier_id = supplier_overrides[pm.id.to_s]
        chosen = if override_supplier_id
          prices.find { |p| p[:supplier].id == override_supplier_id && p[:price].present? }
        end
        chosen ||= in_stock_prices.min_by { |p| p[:price] } if in_stock_prices.any?
        next unless chosen

        most_expensive = in_stock_prices.max_by { |p| p[:price] }

        supplier_list_item = chosen[:item]
        supplier_product = supplier_list_item.supplier_product

        # Skip items without a linked SupplierProduct — linking belongs in the matching phase
        next unless supplier_product

        selected << {
          product_match_id: pm.id,
          supplier_id: chosen[:supplier].id,
          supplier_product_id: supplier_product.id,
          quantity: qty,
          unit_price: supplier_list_item.price || supplier_product.current_price,
          worst_price: most_expensive&.dig(:price)
        }
      end

      selected
    end
  end
end
