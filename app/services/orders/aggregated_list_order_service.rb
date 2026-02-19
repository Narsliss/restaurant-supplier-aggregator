module Orders
  class AggregatedListOrderService
    attr_reader :user, :aggregated_list, :quantities, :location, :delivery_date

    def initialize(user:, aggregated_list:, quantities:, location: nil, delivery_date: nil)
      @user = user
      @aggregated_list = aggregated_list
      @quantities = quantities.transform_keys(&:to_s).transform_values(&:to_i)
      @location = location
      @delivery_date = delivery_date
    end

    # Creates pending Order records grouped by cheapest supplier.
    # SAFETY: Only creates status: "pending" orders. Never calls submit!,
    # PlaceOrderJob, OrderPlacementService, or any scraper code.
    def create_pending_orders!
      selected_items = build_selected_items
      return [] if selected_items.empty?

      by_supplier = selected_items.group_by { |item| item[:supplier_id] }

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
            organization_id: user.current_organization&.id
          )

          items.each do |item|
            order.order_items.create!(
              supplier_product_id: item[:supplier_product_id],
              quantity: item[:quantity],
              unit_price: item[:unit_price],
              line_total: item[:unit_price] * item[:quantity],
              status: "pending"
            )
          end

          order.recalculate_totals!
          order.update!(savings_amount: order.calculate_savings)
          orders << order
        end
      end

      orders
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

        cheapest = pm.cheapest_supplier
        next unless cheapest

        supplier_list_item = cheapest[:item]
        supplier_product = supplier_list_item.supplier_product

        # Attempt to link via SKU match if not already linked
        unless supplier_product
          supplier_list_item.link_to_supplier_product!
          supplier_product = supplier_list_item.reload.supplier_product
        end

        # Skip items without a linked SupplierProduct (OrderItem requires it)
        next unless supplier_product

        selected << {
          product_match_id: pm.id,
          supplier_id: cheapest[:supplier].id,
          supplier_product_id: supplier_product.id,
          quantity: qty,
          unit_price: supplier_product.current_price || supplier_list_item.price
        }
      end

      selected
    end
  end
end
