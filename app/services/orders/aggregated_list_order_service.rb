module Orders
  class AggregatedListOrderService
    attr_reader :user, :aggregated_list, :selections, :location, :delivery_date, :order_list

    def initialize(user:, aggregated_list:, quantities:, supplier_overrides: {}, uom_overrides: {}, location: nil, delivery_date: nil, order_list: nil)
      @user = user
      @aggregated_list = aggregated_list
      @selections = normalize_selections(quantities, supplier_overrides, uom_overrides)
      @location = location
      @delivery_date = delivery_date
      @order_list = order_list
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

          source_name = order_list ? order_list.name : aggregated_list.name
          order = user.orders.create!(
            supplier: supplier,
            location: location,
            status: "pending",
            delivery_date: delivery_date,
            notes: "Created from #{source_name}",
            organization_id: user.current_organization&.id,
            batch_id: batch_id,
            order_list_id: order_list&.id
          )

          # Bulk-insert order items (single INSERT instead of N individual queries)
          now = Time.current
          subtotal = 0
          order_savings = 0

          rows = items.map do |item|
            line_total = item[:unit_price] * item[:quantity]
            subtotal += line_total

            # Dollars are only claimed on a comparison the suppliers' own units
            # settled. An estimated basis still routes the order and still shows
            # its ranking, but the platform does not tell a chef it saved them
            # money on the strength of a pack weight nobody stated.
            claimable = item[:comparison_basis] == "exact"

            # Skip implausible per-line savings — a cross-unit mismatch or bad
            # scrape, not a real deal (order #80 recorded 2,027% saved).
            if claimable && item[:worst_price] && item[:worst_price] > item[:unit_price]
              line_savings = (item[:worst_price] - item[:unit_price]) * item[:quantity]
              if line_savings > line_total * Order::MAX_SAVINGS_MULTIPLE
                Rails.logger.warn "[Savings] #{supplier.name} #{item[:product_name]}: implausible " \
                                  "line savings $#{line_savings.round(2)} on $#{line_total.round(2)} — skipping"
              else
                order_savings += line_savings
              end
            end

            {
              order_id: order.id,
              supplier_product_id: item[:supplier_product_id],
              quantity: item[:quantity],
              unit_price: item[:unit_price],
              line_total: line_total,
              uom: item[:uom],
              status: "pending",
              comparison_basis: item[:comparison_basis],
              # insert_all skips the snapshot_product_info callback — set the
              # name/sku snapshot explicitly or order views show bare SKUs
              product_name: item[:product_name],
              product_sku: item[:product_sku],
              created_at: now,
              updated_at: now
            }
          end

          OrderItem.insert_all!(rows)
          order.update!(subtotal: subtotal, total_amount: subtotal, savings_amount: order_savings.round(2))
          orders << order
        end
      end

      order_list&.touch(:last_used_at) if orders.any?

      [orders, batch_id]
    end

    private

    def build_selected_items
      selected = []

      product_matches = aggregated_list.product_matches
        .where.not(match_status: 'rejected')
        .includes(product_match_items: [:supplier, { supplier_list_item: [:supplier_product, :supplier_list] }])

      product_matches.each do |pm|
        lines = selections[pm.id.to_s]
        next if lines.blank?

        # Compute prices once per match (avoid 3x recalculation via cheapest/most_expensive)
        prices = pm.prices_by_supplier
        most_expensive = pm.most_expensive_supplier

        # A product can be sourced from several suppliers at once. Each line is
        # its own order item; because orders are grouped by supplier below, the
        # lines land in different Orders and no single order ever repeats a
        # product.
        lines.each do |line|
          qty = line[:qty]
          next if qty <= 0

          chosen = if line[:supplier_id]
            prices.find { |p| p[:supplier].id == line[:supplier_id] && p[:price].present? }
          end
          # Use the same per-unit-aware logic as ProductMatch#cheapest_supplier
          # so the order routing matches what the UI highlights as "cheapest".
          chosen ||= pm.cheapest_supplier
          next unless chosen

          supplier_list_item = chosen[:item]
          supplier_product = supplier_list_item.supplier_product

          # Skip items without a linked SupplierProduct — linking belongs in the matching phase
          next unless supplier_product

          # Check for UOM override (CS/PC toggle)
          uom = line[:uom]
          unit_price = if uom == "PC" && supplier_list_item.piece_price.present?
                         supplier_list_item.piece_price
                       else
                         # Use estimated_total_price to convert per-unit prices
                         # (e.g., $18.92/LB) into the full case cost (~$189 for a
                         # 10 LB case). Quantity is in cases, so unit_price must
                         # reflect the cost per case for line_total to be accurate.
                         supplier_list_item.estimated_total_price ||
                           supplier_list_item.price ||
                           supplier_product.current_price
                       end

          selected << {
            product_match_id: pm.id,
            supplier_id: chosen[:supplier].id,
            supplier_product_id: supplier_product.id,
            quantity: qty,
            unit_price: unit_price,
            uom: uom,
            product_name: supplier_product.supplier_name,
            product_sku: supplier_product.supplier_sku,
            comparison_basis: pm.routing_basis,
            worst_price: most_expensive&.dig(:estimated_price) || most_expensive&.dig(:price)
          }
        end
      end

      # Two lines for the same product and supplier would place the same item
      # twice in one order — fold them into one.
      selected
        .group_by { |item| [item[:product_match_id], item[:supplier_id], item[:uom]] }
        .map do |_key, group|
          group.size == 1 ? group.first : group.first.merge(quantity: group.sum { |i| i[:quantity] })
        end
    end

    # Accepts both shapes:
    #   nested  quantities[match_id][supplier_id]  — a product split across suppliers
    #   flat    quantities[match_id] + supplier_overrides[match_id] — the pre-split
    #           form, still sent by saved carts and older clients
    # Returns { match_id => [{ supplier_id:, qty:, uom: }, ...] }, supplier_id
    # nil meaning "whatever the match's cheapest supplier is".
    def normalize_selections(quantities, supplier_overrides, uom_overrides)
      # Params arrive as ActionController::Parameters, which is not Enumerable —
      # flatten to plain hashes before walking them.
      quantities = to_plain_hash(quantities)
      overrides = to_plain_hash(supplier_overrides)
      uoms = to_plain_hash(uom_overrides)

      quantities.each_with_object({}) do |(match_id, value), out|
        match_id = match_id.to_s
        lines = if value.respond_to?(:each_pair)
          value.map do |supplier_id, qty|
            uom = uoms[match_id].respond_to?(:[]) ? uoms[match_id][supplier_id.to_s] : uoms[match_id]
            { supplier_id: supplier_id.to_i, qty: qty.to_i, uom: uom.to_s }
          end
        else
          uom = uoms[match_id]
          uom = uom.values.first if uom.respond_to?(:values)
          [{ supplier_id: overrides[match_id].presence&.to_i, qty: value.to_i, uom: uom.to_s }]
        end
        lines = lines.select { |l| l[:qty] > 0 }
        out[match_id] = lines if lines.any?
      end
    end

    def to_plain_hash(value)
      return {} if value.blank?
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      value.to_h.transform_keys(&:to_s)
    end
  end
end
