class ReportsController < ApplicationController
  before_action :require_organization!
  before_action :require_owner_or_manager!
  before_action :set_date_range

  helper_method :filter_params

  def index
    @locations = accessible_locations
    orders = filtered_orders

    @summary = summary_stats(orders)

    # Breakdown by restaurant
    location_stats = orders.where(location_id: @locations.select(:id))
      .group(:location_id)
      .pluck(
        Arel.sql("location_id"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(savings_amount), 0)")
      ).index_by(&:first)

    @by_restaurant = @locations.map do |loc|
      row = location_stats[loc.id]
      {
        location: loc,
        total_spent: row ? row[1] : 0,
        order_count: row ? row[2] : 0,
        savings: row ? row[3] : 0
      }
    end.sort_by { |r| -r[:total_spent] }

    @by_supplier = supplier_breakdown(orders)
    @by_member = member_breakdown(orders)
    @weekly_trend = weekly_trend(orders)
  end

  def location
    @locations = accessible_locations
    @location = @locations.find(params[:location_id])
    orders = base_orders.for_location(@location)

    @summary = summary_stats(orders)
    @by_supplier = supplier_breakdown(orders)
    @top_products = top_products(orders)
    @weekly_trend = weekly_trend(orders)
    @by_member = member_breakdown(orders)
  end

  def supplier
    @locations = accessible_locations
    @supplier = Supplier.find(params[:supplier_id])
    orders = filtered_orders.where(supplier: @supplier)

    @summary = summary_stats(orders)
    @top_products = top_products(orders)

    # Order frequency
    freq = orders.pick(
      Arel.sql("MIN(orders.created_at)"),
      Arel.sql("MAX(orders.created_at)")
    )
    first_order, last_order = freq[0], freq[1]
    @order_frequency_days = if @summary[:order_count] > 1 && first_order && last_order
      ((last_order - first_order) / (@summary[:order_count] - 1) / 1.day).round(1)
    end

    # Which locations order from this supplier
    location_rows = orders
      .where(location_id: @locations.select(:id))
      .group(:location_id)
      .pluck(
        Arel.sql("location_id"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(savings_amount), 0)")
      )
    locations_by_id = Location.where(id: location_rows.map(&:first)).index_by(&:id)
    @by_location = location_rows.filter_map do |row|
      loc = locations_by_id[row[0]]
      next unless loc
      { location: loc, total_spent: row[1], order_count: row[2], savings: row[3] }
    end.sort_by { |r| -r[:total_spent] }
  end

  def member
    @locations = accessible_locations
    org = current_user.current_organization

    # Find the user — must be in the same org
    @member = User.joins(:memberships)
                  .where(memberships: { organization_id: org.id })
                  .find(params[:user_id])

    orders = filtered_orders.where(user: @member)

    @summary = summary_stats(orders)
    @by_supplier = supplier_breakdown(orders)
    @top_products = top_products(orders)
    @weekly_trend = weekly_trend(orders)

    # Recent orders (last 10)
    @recent_orders = orders.order(created_at: :desc).limit(10)
                           .includes(:supplier, :location)

    # Per-user missed savings — same logic as the main missed_savings action
    # but scoped to this member's orders
    promoted = AggregatedList.where(organization_id: org.id).promoted.first
    if promoted
      agg_lists = AggregatedList.where(id: promoted.id)
    else
      agg_lists = AggregatedList.where(organization_id: org.id)
                                .where(location_id: @locations.select(:id))
                                .matched_lists
    end

    @missed_items = []
    @total_potential_savings = 0

    if agg_lists.any?
      ordered_items = OrderItem
        .joins(:order)
        .where(orders: { id: orders.select(:id) })
        .where.not(supplier_product_id: nil)
        .group(:supplier_product_id)
        .pluck(
          Arel.sql("order_items.supplier_product_id"),
          Arel.sql("MAX(order_items.product_name)"),
          Arel.sql("AVG(order_items.unit_price)"),
          Arel.sql("SUM(order_items.quantity)"),
          Arel.sql("SUM(order_items.line_total)")
        )

      if ordered_items.any?
        sp_ids = ordered_items.map(&:first)
        match_items = ProductMatchItem
          .joins(:supplier_list_item)
          .where(supplier_list_items: { supplier_product_id: sp_ids })
          .where(product_match_id: agg_lists.joins(:product_matches).select("product_matches.id"))
          .includes(product_match: { product_match_items: [{ supplier_list_item: :supplier_product }, :supplier] })
          .index_by { |pmi| pmi.supplier_list_item.supplier_product_id }

        @missed_items = ordered_items.filter_map do |sp_id, name, avg_price, total_qty, total_spent|
          pmi = match_items[sp_id]
          next unless pmi
          pm = pmi.product_match
          cheapest = pm.cheapest_supplier
          ordered_supplier = pmi.supplier
          next unless cheapest && cheapest[:supplier].id != ordered_supplier.id
          next unless cheapest[:price] && avg_price && cheapest[:price] < avg_price
          savings_per_unit = avg_price - cheapest[:price]
          {
            product_name: name,
            ordered_from: ordered_supplier.name,
            ordered_price: avg_price.round(2),
            cheaper_supplier: cheapest[:supplier].name,
            cheaper_price: cheapest[:price].round(2),
            savings_per_order: savings_per_unit.round(2),
            total_potential_savings: (savings_per_unit * total_qty).round(2),
            total_qty: total_qty.round(1)
          }
        end.sort_by { |r| -r[:total_potential_savings] }

        @total_potential_savings = @missed_items.sum { |r| r[:total_potential_savings] }
      end
    end
  end

  def savings
    orders = filtered_orders

    # Per-product savings: what we paid vs most expensive alternative
    # Join order_items → supplier_products, then subquery for max price per product
    @product_savings = OrderItem
      .joins(:order)
      .joins("INNER JOIN supplier_products ON supplier_products.id = order_items.supplier_product_id")
      .joins(<<~SQL)
        INNER JOIN (
          SELECT product_id, MAX(current_price) AS max_price
          FROM supplier_products
          WHERE discontinued = false AND current_price IS NOT NULL
          GROUP BY product_id
        ) max_prices ON max_prices.product_id = supplier_products.product_id
      SQL
      .where(orders: { id: orders.select(:id) })
      .where("max_prices.max_price > order_items.unit_price")
      .where.not(order_items: { supplier_product_id: nil })
      .group("order_items.product_name")
      .order(Arel.sql("SUM((max_prices.max_price - order_items.unit_price) * order_items.quantity) DESC"))
      .limit(50)
      .pluck(
        Arel.sql("order_items.product_name"),
        Arel.sql("SUM(order_items.line_total)"),
        Arel.sql("SUM(max_prices.max_price * order_items.quantity)"),
        Arel.sql("SUM((max_prices.max_price - order_items.unit_price) * order_items.quantity)"),
        Arel.sql("SUM(order_items.quantity)")
      )

    @total_realized_savings = @product_savings.sum { |r| r[3].to_f }
  end

  def missed_savings
    org = current_user.current_organization

    # Prefer the promoted list (org-wide standard matches) if one exists.
    # Fall back to location-based matched lists only when no promoted list is set.
    promoted = AggregatedList.where(organization_id: org.id).promoted.first
    if promoted
      @aggregated_lists = AggregatedList.where(id: promoted.id)
    else
      @aggregated_lists = AggregatedList.where(organization_id: org.id)
                                        .where(location_id: accessible_locations.select(:id))
                                        .matched_lists
    end
    @has_matched_lists = @aggregated_lists.any?
    return @missed_items = [] unless @has_matched_lists

    orders = filtered_orders

    # Get all ordered products with their spend
    ordered_items = OrderItem
      .joins(:order)
      .where(orders: { id: orders.select(:id) })
      .where.not(supplier_product_id: nil)
      .group(:supplier_product_id)
      .pluck(
        Arel.sql("order_items.supplier_product_id"),
        Arel.sql("MAX(order_items.product_name)"),
        Arel.sql("AVG(order_items.unit_price)"),
        Arel.sql("SUM(order_items.quantity)"),
        Arel.sql("SUM(order_items.line_total)")
      )

    return @missed_items = [] if ordered_items.empty?

    # Find product_match_items across all matched lists for these supplier_products
    sp_ids = ordered_items.map(&:first)
    match_items = ProductMatchItem
      .joins(:supplier_list_item)
      .where(supplier_list_items: { supplier_product_id: sp_ids })
      .where(product_match_id: @aggregated_lists.joins(:product_matches).select("product_matches.id"))
      .includes(product_match: { product_match_items: [{ supplier_list_item: :supplier_product }, :supplier] })
      .index_by { |pmi| pmi.supplier_list_item.supplier_product_id }

    @missed_items = ordered_items.filter_map do |sp_id, name, avg_price, total_qty, total_spent|
      pmi = match_items[sp_id]
      next unless pmi

      pm = pmi.product_match
      cheapest = pm.cheapest_supplier
      ordered_supplier = pmi.supplier

      # Only show if cheapest is a different supplier and actually cheaper
      next unless cheapest && cheapest[:supplier].id != ordered_supplier.id
      next unless cheapest[:price] && avg_price && cheapest[:price] < avg_price

      savings_per_unit = avg_price - cheapest[:price]
      {
        product_name: name,
        ordered_from: ordered_supplier.name,
        ordered_price: avg_price.round(2),
        cheaper_supplier: cheapest[:supplier].name,
        cheaper_price: cheapest[:price].round(2),
        savings_per_order: savings_per_unit.round(2),
        total_potential_savings: (savings_per_unit * total_qty).round(2),
        total_qty: total_qty.round(1)
      }
    end.sort_by { |r| -r[:total_potential_savings] }

    @total_potential_savings = @missed_items.sum { |r| r[:total_potential_savings] }
  end

  private

  def set_date_range
    @start_date = params[:start_date]&.to_date || 30.days.ago.to_date
    @end_date = params[:end_date]&.to_date || Date.current
    @date_range = @start_date.beginning_of_day..@end_date.end_of_day
    @selected_location_id = params[:location_id]&.to_i
  end

  def base_orders
    scoped_orders.kpi_eligible.where(created_at: @date_range)
  end

  def filtered_orders
    orders = base_orders
    orders = orders.for_location(Location.find(@selected_location_id)) if @selected_location_id.present? && @selected_location_id > 0
    orders
  end

  def filter_params
    p = { start_date: @start_date, end_date: @end_date }
    p[:location_id] = @selected_location_id if @selected_location_id.present? && @selected_location_id > 0
    p
  end

  def summary_stats(orders)
    row = orders.pick(
      Arel.sql("COALESCE(SUM(total_amount), 0)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)"),
      Arel.sql("COUNT(*)"),
      Arel.sql("CASE WHEN COUNT(*) > 0 THEN ROUND(SUM(total_amount) / COUNT(*), 2) ELSE 0 END")
    )
    { total_spent: row[0], total_savings: row[1], order_count: row[2], avg_order_size: row[3] }
  end

  def supplier_breakdown(orders)
    rows = orders.group(:supplier_id).pluck(
      Arel.sql("supplier_id"),
      Arel.sql("COALESCE(SUM(total_amount), 0)"),
      Arel.sql("COUNT(*)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)")
    )
    suppliers = Supplier.where(id: rows.map(&:first)).index_by(&:id)
    rows.filter_map do |row|
      s = suppliers[row[0]]
      next unless s
      { supplier: s, total_spent: row[1], order_count: row[2], savings: row[3] }
    end.sort_by { |r| -r[:total_spent] }
  end

  def member_breakdown(orders)
    rows = orders.group(:user_id).pluck(
      Arel.sql("user_id"),
      Arel.sql("COALESCE(SUM(total_amount), 0)"),
      Arel.sql("COUNT(*)")
    )
    users = User.where(id: rows.map(&:first)).index_by(&:id)
    rows.filter_map do |row|
      u = users[row[0]]
      next unless u
      { user: u, total_spent: row[1], order_count: row[2] }
    end.sort_by { |r| -r[:total_spent] }
  end

  def top_products(orders, limit: 20)
    OrderItem
      .joins(:order)
      .where(orders: { id: orders.select(:id) })
      .group("order_items.product_name")
      .order(Arel.sql("SUM(order_items.line_total) DESC"))
      .limit(limit)
      .pluck(
        Arel.sql("order_items.product_name"),
        Arel.sql("SUM(order_items.quantity)"),
        Arel.sql("SUM(order_items.line_total)"),
        Arel.sql("COUNT(DISTINCT orders.id)")
      )
  end

  def weekly_trend(orders)
    eight_weeks_ago = 8.weeks.ago.beginning_of_week.beginning_of_day
    data = orders.where("orders.created_at >= ?", eight_weeks_ago)
      .group(Arel.sql("date_trunc('week', orders.created_at)"))
      .pluck(
        Arel.sql("date_trunc('week', orders.created_at)"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)")
      ).index_by { |row| row[0].to_date }

    (0..7).map do |weeks_ago|
      week_start = (Date.current - weeks_ago.weeks).beginning_of_week
      row = data[week_start]
      { week: week_start, label: week_start.strftime("%b %d"), total: row ? row[1] : 0, count: row ? row[2] : 0 }
    end.reverse
  end
end
