module Orders
  class PriceComparisonService
    attr_reader :order_list, :user

    def initialize(order_list)
      @order_list = order_list
      @user = order_list.user
    end

    def compare
      items = order_list.order_list_items.includes(product: { supplier_products: :supplier })

      comparison = items.map do |item|
        product = item.product
        supplier_prices = build_supplier_prices(product, item.quantity)

        {
          id: item.id,
          product: {
            id: product.id,
            name: product.name,
            category: product.category,
            unit_size: product.unit_size
          },
          quantity: item.quantity,
          notes: item.notes,
          suppliers: supplier_prices,
          best_price: find_best_price(supplier_prices),
          worst_price: find_worst_price(supplier_prices),
          price_spread: calculate_spread(supplier_prices)
        }
      end

      {
        order_list: {
          id: order_list.id,
          name: order_list.name
        },
        items: comparison,
        totals_by_supplier: calculate_totals(comparison),
        summary: generate_summary(comparison),
        recommendations: generate_recommendations(comparison)
      }
    end

    def refresh_prices!
      active_suppliers.each do |supplier|
        credential = user.credential_for(supplier)
        next unless credential&.active?

        ScrapeSupplierJob.perform_later(supplier.id, credential.id)
      end
    end

    private

    def build_supplier_prices(product, quantity)
      supplier_pairs = active_suppliers.map do |supplier|
        sp = product.supplier_products.find { |sp| sp.supplier_id == supplier.id }
        [supplier, sp]
      end

      # Determine if per-unit comparison is possible (all parseable suppliers share the same unit category)
      parseable_units = supplier_pairs
        .filter_map { |_, sp| sp&.normalized_unit }
        .uniq
      comparable = parseable_units.size == 1
      comparison_unit = parseable_units.first if comparable

      supplier_pairs.map do |supplier, supplier_product|
        if supplier_product&.current_price
          {
            supplier: {
              id: supplier.id,
              name: supplier.name,
              code: supplier.code
            },
            supplier_product_id: supplier_product.id,
            supplier_sku: supplier_product.supplier_sku,
            unit_price: supplier_product.current_price,
            line_total: supplier_product.current_price * quantity,
            pack_size: supplier_product.pack_size,
            per_unit_price: supplier_product.per_unit_price,
            normalized_unit: supplier_product.normalized_unit,
            formatted_per_unit: supplier_product.formatted_per_unit_price,
            comparable: comparable,
            comparison_unit: comparison_unit,
            in_stock: supplier_product.in_stock?,
            last_updated: supplier_product.price_updated_at,
            price_changed: supplier_product.price_changed?,
            price_change_percent: supplier_product.price_change_percent
          }
        else
          {
            supplier: {
              id: supplier.id,
              name: supplier.name,
              code: supplier.code
            },
            supplier_product_id: nil,
            supplier_sku: nil,
            unit_price: nil,
            line_total: nil,
            pack_size: nil,
            per_unit_price: nil,
            normalized_unit: nil,
            formatted_per_unit: nil,
            comparable: false,
            comparison_unit: nil,
            in_stock: false,
            last_updated: nil,
            unavailable: true
          }
        end
      end
    end

    def active_suppliers
      @active_suppliers ||= begin
        # Get suppliers where user has active credentials
        user_supplier_ids = user.supplier_credentials
          .where(status: "active")
          .pluck(:supplier_id)
        
        Supplier.active.where(id: user_supplier_ids).order(:name)
      end
    end

    def find_best_price(supplier_prices)
      available = supplier_prices.select { |sp| sp[:in_stock] && sp[:unit_price] }
      return nil if available.empty?

      # Use per-unit price when comparable, otherwise fall back to pack price
      best = if available.any? { |sp| sp[:comparable] && sp[:per_unit_price] }
        available.select { |sp| sp[:per_unit_price] }.min_by { |sp| sp[:per_unit_price] }
      else
        available.min_by { |sp| sp[:unit_price] }
      end

      {
        supplier_id: best.dig(:supplier, :id),
        supplier_name: best.dig(:supplier, :name),
        unit_price: best[:unit_price],
        line_total: best[:line_total],
        per_unit_price: best[:per_unit_price],
        compared_by_unit: best[:comparable] && best[:per_unit_price].present?
      }
    end

    def find_worst_price(supplier_prices)
      available = supplier_prices.select { |sp| sp[:in_stock] && sp[:unit_price] }
      return nil if available.empty?

      worst = if available.any? { |sp| sp[:comparable] && sp[:per_unit_price] }
        available.select { |sp| sp[:per_unit_price] }.max_by { |sp| sp[:per_unit_price] }
      else
        available.max_by { |sp| sp[:unit_price] }
      end

      {
        supplier_id: worst.dig(:supplier, :id),
        supplier_name: worst.dig(:supplier, :name),
        unit_price: worst[:unit_price],
        line_total: worst[:line_total],
        per_unit_price: worst[:per_unit_price]
      }
    end

    def calculate_spread(supplier_prices)
      # Use per-unit spread when comparable
      if supplier_prices.any? { |sp| sp[:comparable] && sp[:per_unit_price] }
        per_unit_prices = supplier_prices.filter_map { |sp| sp[:per_unit_price] if sp[:comparable] }
        return 0 if per_unit_prices.size < 2
        (per_unit_prices.max - per_unit_prices.min).round(4)
      else
        prices = supplier_prices.map { |sp| sp[:unit_price] }.compact
        return 0 if prices.size < 2
        (prices.max - prices.min).round(2)
      end
    end

    def calculate_totals(comparison)
      totals = {}
      
      active_suppliers.each do |supplier|
        totals[supplier.id] = {
          supplier_id: supplier.id,
          supplier_name: supplier.name,
          supplier_code: supplier.code,
          total: 0,
          available_items: 0,
          missing_items: 0,
          order_minimum: supplier.order_minimum,
          meets_minimum: false
        }
      end

      comparison.each do |item|
        item[:suppliers].each do |sp|
          supplier_id = sp.dig(:supplier, :id)
          next unless totals[supplier_id]

          if sp[:line_total] && sp[:in_stock]
            totals[supplier_id][:total] += sp[:line_total]
            totals[supplier_id][:available_items] += 1
          else
            totals[supplier_id][:missing_items] += 1
          end
        end
      end

      # Check if each supplier meets their minimum
      totals.each do |_id, data|
        minimum = data[:order_minimum]
        data[:meets_minimum] = minimum.nil? || data[:total] >= minimum
        data[:amount_to_minimum] = minimum ? [minimum - data[:total], 0].max : 0
      end

      totals
    end

    def generate_summary(comparison)
      total_items = comparison.size
      
      {
        total_items: total_items,
        total_quantity: comparison.sum { |c| c[:quantity] },
        suppliers_compared: active_suppliers.count,
        items_with_all_suppliers: comparison.count { |c| c[:suppliers].none? { |s| s[:unavailable] } },
        items_with_price_spread: comparison.count { |c| c[:price_spread] > 0 },
        potential_savings: calculate_potential_savings(comparison)
      }
    end

    def generate_recommendations(comparison)
      totals = calculate_totals(comparison)

      # Find best single supplier (all items available, meets minimum, lowest total)
      complete_suppliers = totals.select do |_id, data|
        data[:missing_items] == 0 && data[:meets_minimum]
      end

      best_single = if complete_suppliers.any?
        best = complete_suppliers.min_by { |_id, data| data[:total] }
        {
          supplier_id: best[0],
          supplier_name: best[1][:supplier_name],
          total: best[1][:total]
        }
      else
        nil
      end

      # Calculate split order savings
      split_savings = calculate_split_savings(comparison, totals)

      {
        best_single_supplier: best_single,
        split_order_savings: split_savings,
        recommendation: generate_recommendation_text(best_single, split_savings, totals)
      }
    end

    def calculate_potential_savings(comparison)
      # Savings if you ordered each item from cheapest vs most expensive
      total_best = comparison.sum { |c| c[:best_price]&.dig(:line_total) || 0 }
      total_worst = comparison.sum { |c| c[:worst_price]&.dig(:line_total) || 0 }
      
      (total_worst - total_best).round(2)
    end

    def calculate_split_savings(comparison, totals)
      # Best single supplier total
      complete_totals = totals.values.select { |t| t[:missing_items] == 0 }
      return 0 if complete_totals.empty?

      single_best = complete_totals.map { |t| t[:total] }.min

      # Split order total (each item from cheapest)
      split_total = comparison.sum { |c| c[:best_price]&.dig(:line_total) || 0 }

      (single_best - split_total).round(2)
    end

    def generate_recommendation_text(best_single, split_savings, totals)
      if best_single.nil?
        incomplete = totals.values.select { |t| t[:missing_items] > 0 }
        if incomplete.any?
          "No single supplier has all items available. Consider splitting your order or finding alternative products."
        else
          "No suppliers meet their order minimums. Add more items to your order."
        end
      elsif split_savings > 10
        "You could save #{format_currency(split_savings)} by splitting your order across multiple suppliers. However, #{best_single[:supplier_name]} has all items for #{format_currency(best_single[:total])}."
      else
        "Order from #{best_single[:supplier_name]} for the best value at #{format_currency(best_single[:total])}."
      end
    end

    def format_currency(amount)
      "$#{'%.2f' % amount}"
    end
  end
end
