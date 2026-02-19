module Orders
  class SplitOrderService
    attr_reader :order_list, :user, :location

    def initialize(order_list, location: nil)
      @order_list = order_list
      @user = order_list.user
      @location = location || user.default_location
    end

    # Preview what a split order would look like
    def preview
      assignments = assign_items_to_suppliers

      {
        strategy: 'best_price',
        assignments: assignments.map do |supplier_id, items|
          supplier = suppliers_by_id[supplier_id]
          subtotal = items.sum { |i| i[:line_total] }

          {
            supplier: {
              id: supplier.id,
              name: supplier.name,
              order_minimum: supplier.order_minimum
            },
            items: items,
            item_count: items.size,
            subtotal: subtotal,
            meets_minimum: meets_minimum?(supplier, subtotal),
            amount_to_minimum: amount_to_minimum(supplier, subtotal)
          }
        end,
        summary: build_summary(assignments),
        warnings: build_warnings(assignments)
      }
    end

    # Create all the split orders at once
    def create_orders!(delivery_date: nil)
      assignments = assign_items_to_suppliers

      # Validate all suppliers meet minimums
      assignments.each do |supplier_id, items|
        supplier = suppliers_by_id[supplier_id]
        subtotal = items.sum { |i| i[:line_total] }

        next if meets_minimum?(supplier, subtotal)

        raise OrderMinimumError.new(
          "#{supplier.name} order minimum not met",
          supplier: supplier,
          minimum: supplier.order_minimum,
          current: subtotal
        )
      end

      orders = []

      ActiveRecord::Base.transaction do
        assignments.each do |supplier_id, items|
          supplier = suppliers_by_id[supplier_id]

          order = user.orders.create!(
            supplier: supplier,
            location: location,
            order_list: order_list,
            status: 'pending',
            delivery_date: delivery_date,
            notes: 'Split order - best price per item'
          )

          items.each do |item|
            order.order_items.create!(
              supplier_product_id: item[:supplier_product_id],
              quantity: item[:quantity],
              unit_price: item[:unit_price],
              line_total: item[:line_total],
              status: 'pending'
            )
          end

          order.recalculate_totals!
          order.update!(savings_amount: order.calculate_savings)
          orders << order
        end

        order_list.mark_used!
      end

      orders
    end

    # Submit all split orders
    def submit_all!(orders, accept_price_changes: false)
      results = []

      orders.each do |order|
        PlaceOrderJob.perform_later(
          order.id,
          accept_price_changes: accept_price_changes
        )
        order.update!(status: 'processing')
        results << { order: order, status: 'submitted' }
      rescue StandardError => e
        results << { order: order, status: 'failed', error: e.message }
      end

      results
    end

    private

    def assign_items_to_suppliers
      assignments = Hash.new { |h, k| h[k] = [] }
      unassigned = []

      order_list.order_list_items.includes(product: { supplier_products: :supplier }).each do |list_item|
        product = list_item.product
        best_option = find_best_supplier_for_product(product, list_item.quantity)

        if best_option
          assignments[best_option[:supplier_id]] << {
            order_list_item_id: list_item.id,
            product_id: product.id,
            product_name: product.name,
            supplier_product_id: best_option[:supplier_product_id],
            supplier_sku: best_option[:supplier_sku],
            supplier_name: best_option[:supplier_name],
            quantity: list_item.quantity,
            unit_price: best_option[:unit_price],
            line_total: best_option[:line_total]
          }
        else
          unassigned << {
            product_id: product.id,
            product_name: product.name,
            quantity: list_item.quantity,
            reason: 'No supplier has this item in stock'
          }
        end
      end

      # Store unassigned for warnings
      @unassigned_items = unassigned

      assignments
    end

    def find_best_supplier_for_product(product, quantity)
      options = []

      product.supplier_products.each do |sp|
        next if sp.discontinued?
        next unless sp.in_stock? && sp.current_price.present?
        next unless active_supplier_ids.include?(sp.supplier_id)

        options << {
          supplier_id: sp.supplier_id,
          supplier_name: sp.supplier.name,
          supplier_product_id: sp.id,
          supplier_sku: sp.supplier_sku,
          unit_price: sp.current_price,
          line_total: sp.current_price * quantity
        }
      end

      # Return cheapest option
      options.min_by { |o| o[:unit_price] }
    end

    def active_supplier_ids
      @active_supplier_ids ||= user.supplier_credentials
                                   .where(status: 'active')
                                   .pluck(:supplier_id)
    end

    def suppliers_by_id
      @suppliers_by_id ||= Supplier.where(id: active_supplier_ids).index_by(&:id)
    end

    def meets_minimum?(supplier, subtotal)
      supplier.order_minimum.nil? || subtotal >= supplier.order_minimum
    end

    def amount_to_minimum(supplier, subtotal)
      return 0 if supplier.order_minimum.nil?

      [supplier.order_minimum - subtotal, 0].max
    end

    def build_summary(assignments)
      total_items = assignments.values.sum(&:size)
      total_amount = assignments.sum do |_supplier_id, items|
        items.sum { |i| i[:line_total] }
      end

      {
        total_items: total_items,
        total_amount: total_amount,
        supplier_count: assignments.size,
        unassigned_count: @unassigned_items&.size || 0
      }
    end

    def build_warnings(assignments)
      warnings = []

      # Check for unassigned items
      if @unassigned_items&.any?
        warnings << {
          type: 'unassigned_items',
          message: "#{@unassigned_items.size} item(s) could not be assigned to any supplier",
          items: @unassigned_items
        }
      end

      # Check for order minimums not met
      assignments.each do |supplier_id, items|
        supplier = suppliers_by_id[supplier_id]
        subtotal = items.sum { |i| i[:line_total] }

        next if meets_minimum?(supplier, subtotal)

        warnings << {
          type: 'minimum_not_met',
          message: "#{supplier.name} requires a minimum order of $#{'%.2f' % supplier.order_minimum}",
          supplier_id: supplier_id,
          supplier_name: supplier.name,
          current_total: subtotal,
          minimum: supplier.order_minimum,
          shortfall: amount_to_minimum(supplier, subtotal)
        }
      end

      warnings
    end

    class OrderMinimumError < StandardError
      attr_reader :supplier, :minimum, :current

      def initialize(message, supplier:, minimum:, current:)
        @supplier = supplier
        @minimum = minimum
        @current = current
        super(message)
      end
    end
  end
end
