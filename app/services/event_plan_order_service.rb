# Creates pending Order records from a finalized EventPlan's menu.
# Follows the same pattern as Orders::AggregatedListOrderService.
#
# Usage:
#   service = EventPlanOrderService.new(event_plan: plan, user: user, location: location)
#   orders, batch_id = service.create_pending_orders!
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
    return [[], nil] if items.empty?

    by_supplier = items.group_by { |item| item[:supplier_id] }

    batch_id = SecureRandom.uuid
    orders = []

    ActiveRecord::Base.transaction do
      by_supplier.each do |supplier_id, supplier_items|
        supplier = Supplier.find(supplier_id)

        order = user.orders.create!(
          supplier: supplier,
          location: location,
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

    [orders, batch_id]
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

  def calculate_order_quantity(ingredient, supplier_product)
    # Default to 1 pack if we can't determine the right quantity.
    # Real precision would require pack size parsing against ingredient units,
    # which is a refinement for later.
    qty = ingredient["quantity"].to_f
    return 1 if qty <= 0

    # If the supplier product has a parseable pack size, try to calculate packs needed
    parsed = supplier_product.parsed_pack_size
    if parsed[:parseable] && parsed[:normalized_quantity] > 0
      packs_needed = (qty / parsed[:normalized_quantity]).ceil
      [packs_needed, 1].max
    else
      # Can't parse pack size — order 1 unit and let the chef adjust in review
      1
    end
  end
end
