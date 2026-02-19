module Orders
  class OrderBuilderService
    attr_reader :user, :order_list, :supplier, :location

    def initialize(user:, order_list:, supplier:, location: nil)
      @user = user
      @order_list = order_list
      @supplier = supplier
      @location = location || user.default_location
    end

    def build
      order = user.orders.new(
        location: location,
        supplier: supplier,
        order_list: order_list,
        status: "pending"
      )

      order_list.order_list_items.includes(product: :supplier_products).each do |list_item|
        supplier_product = list_item.product.supplier_product_for(supplier)
        
        # Skip items not available at this supplier
        next unless supplier_product&.current_price

        order.order_items.build(
          supplier_product: supplier_product,
          quantity: list_item.quantity,
          unit_price: supplier_product.current_price,
          line_total: supplier_product.current_price * list_item.quantity,
          status: "pending"
        )
      end

      # Calculate totals
      order.subtotal = order.order_items.sum(&:line_total)
      order.total_amount = order.subtotal # Tax calculated later if needed
      order.savings_amount = order.calculate_savings

      order
    end

    def build_and_save!
      order = build
      
      if order.order_items.empty?
        raise ArgumentError, "No items available from #{supplier.name} for this order list"
      end

      order.save!
      order_list.mark_used!
      
      order
    end

    def preview
      order = build

      available_items = order.order_items.to_a
      missing_items = find_missing_items

      {
        supplier: {
          id: supplier.id,
          name: supplier.name,
          order_minimum: supplier.order_minimum
        },
        location: location ? {
          id: location.id,
          name: location.name,
          address: location.full_address
        } : nil,
        items: available_items.map do |item|
          {
            product_name: item.supplier_product.supplier_name,
            supplier_sku: item.supplier_product.supplier_sku,
            quantity: item.quantity,
            unit_price: item.unit_price,
            line_total: item.line_total,
            in_stock: item.supplier_product.in_stock?
          }
        end,
        missing_items: missing_items.map do |item|
          {
            product_name: item.product.name,
            quantity: item.quantity
          }
        end,
        subtotal: order.subtotal,
        total_amount: order.total_amount,
        item_count: available_items.size,
        missing_count: missing_items.size,
        meets_minimum: meets_minimum?(order.subtotal),
        amount_to_minimum: amount_to_minimum(order.subtotal)
      }
    end

    private

    def find_missing_items
      order_list.order_list_items.select do |item|
        supplier_product = item.product.supplier_product_for(supplier)
        supplier_product.nil? || supplier_product.current_price.nil?
      end
    end

    def meets_minimum?(subtotal)
      minimum = supplier.order_minimum
      minimum.nil? || subtotal >= minimum
    end

    def amount_to_minimum(subtotal)
      minimum = supplier.order_minimum
      return 0 if minimum.nil?
      [minimum - subtotal, 0].max
    end
  end
end
