# Creates pending Order records and an OrderList from an EventPlan's menu.
# Follows the same pattern as Orders::AggregatedListOrderService.
#
# The OrderList is a persistent, editable list of all the menu ingredients
# so the chef can add additional items before submitting orders.
#
# Usage:
#   service = EventPlanOrderService.new(event_plan: plan, user: user, location: location)
#   orders, batch_id, order_list = service.create_pending_orders!
#
class EventPlanOrderService
  attr_reader :event_plan, :user, :location

  def initialize(event_plan:, user:, location: nil)
    @event_plan = event_plan
    @user = user
    @location = location
  end

  def create_pending_orders!
    items = collect_orderable_items
    return [[], nil, nil] if items.empty?

    by_supplier = items.group_by { |item| item[:supplier_id] }

    batch_id = SecureRandom.uuid
    orders = []
    order_list = nil

    ActiveRecord::Base.transaction do
      # Create an OrderList so the chef can add/edit items
      order_list = create_order_list!(items)

      by_supplier.each do |supplier_id, supplier_items|
        supplier = Supplier.find(supplier_id)

        order = user.orders.create!(
          supplier: supplier,
          location: location,
          order_list: order_list,
          status: "pending",
          notes: "Created from Menu Planner: #{event_plan.title}",
          organization_id: user.current_organization&.id,
          batch_id: batch_id
        )

        now = Time.current
        subtotal = 0

        rows = supplier_items.map do |item|
          line_total = item[:unit_price] * item[:quantity]
          subtotal += line_total

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
        order.update!(subtotal: subtotal, total_amount: subtotal)
        orders << order
      end
    end

    [orders, batch_id, order_list]
  end

  private

  def collect_orderable_items
    items = []
    courses = event_plan.courses

    courses.each do |course|
      (course["ingredients"] || []).each do |ingredient|
        matched = ingredient["matched_product"]
        next unless matched && matched["supplier_product_id"]

        sp = SupplierProduct.find_by(id: matched["supplier_product_id"])
        next unless sp

        items << {
          supplier_id: sp.supplier_id,
          supplier_product_id: sp.id,
          quantity: calculate_order_quantity(ingredient, sp),
          unit_price: sp.current_price || matched["unit_price"]
        }
      end
    end

    # Deduplicate: if the same supplier product appears in multiple courses, sum quantities
    items.group_by { |i| i[:supplier_product_id] }.map do |_sp_id, group|
      {
        supplier_id: group.first[:supplier_id],
        supplier_product_id: group.first[:supplier_product_id],
        quantity: group.sum { |i| i[:quantity] },
        unit_price: group.first[:unit_price]
      }
    end
  end

  def create_order_list!(items)
    list_name = event_plan.title.presence || "Menu Plan"
    # Ensure unique name by appending a number if needed
    base_name = list_name
    counter = 1
    while OrderList.where(user: user, location: location, name: list_name).exists?
      counter += 1
      list_name = "#{base_name} (#{counter})"
    end

    order_list = OrderList.create!(
      user: user,
      organization: user.current_organization,
      location: location,
      name: list_name,
      description: "Generated from Menu Planner — #{event_plan.covers || '?'} covers",
      last_used_at: Time.current
    )

    # Add each matched ingredient as an OrderListItem (via its normalized Product)
    position = 0
    items.each do |item|
      sp = SupplierProduct.find_by(id: item[:supplier_product_id])
      next unless sp&.product_id

      # Skip duplicates — same product may appear in multiple courses (already deduped in items)
      next if order_list.order_list_items.exists?(product_id: sp.product_id)

      order_list.order_list_items.create!(
        product_id: sp.product_id,
        quantity: item[:quantity],
        position: position
      )
      position += 1
    end

    order_list
  end

  def calculate_order_quantity(ingredient, supplier_product)
    qty = ingredient["quantity"].to_f
    recipe_unit = ingredient["unit"].to_s.strip
    return 1 if qty <= 0

    product_parsed = supplier_product.parsed_pack_size
    return 1 unless product_parsed[:parseable] && product_parsed[:normalized_quantity] > 0

    recipe_parsed = UnitParser.parse("#{qty} #{recipe_unit}")

    # Path 1: Same normalized unit (e.g., both → oz, both → fl oz)
    if recipe_parsed[:parseable] &&
       recipe_parsed[:normalized_unit] == product_parsed[:normalized_unit]
      packs = (recipe_parsed[:normalized_quantity] / product_parsed[:normalized_quantity]).ceil
      return [packs, 1].max
    end

    # Path 2: Same raw unit (e.g., both "bunch")
    if recipe_parsed[:parseable]
      recipe_key = UnitParser.normalize_unit_key(recipe_unit)
      product_key = UnitParser.normalize_unit_key(product_parsed[:unit].to_s)
      if recipe_key == product_key && product_parsed[:quantity].to_f > 0
        packs = (qty / product_parsed[:quantity]).ceil
        return [packs, 1].max
      end
    end

    # Path 3: Weight ↔ Volume approximation (1 oz ≈ 1 fl oz)
    if recipe_parsed[:parseable]
      r = recipe_parsed[:normalized_unit]
      p = product_parsed[:normalized_unit]
      if (r == "oz" && p == "fl oz") || (r == "fl oz" && p == "oz")
        packs = (recipe_parsed[:normalized_quantity] / product_parsed[:normalized_quantity]).ceil
        return [packs, 1].max
      end
    end

    # Fallback: can't convert — order 1 pack, chef adjusts in review
    1
  end
end
