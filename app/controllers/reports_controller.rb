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
    @monthly_trend = monthly_trend(orders)
  end

  def location
    @locations = accessible_locations
    @location = @locations.find(params[:location_id])
    orders = base_orders.for_location(@location)

    @summary = summary_stats(orders)
    @by_supplier = supplier_breakdown(orders)
    @top_products = top_products(orders)
    @weekly_trend = weekly_trend(orders)
    @monthly_trend = monthly_trend(orders)
    @by_member = member_breakdown(orders)

    @product_savings = product_savings_for(orders)
    @total_realized_savings = @product_savings.sum { |r| r[3].to_f }
    @missed_items = missed_savings_for(orders)
    @total_missed_savings = @missed_items.sum { |r| r[:total_potential_savings] }
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

    @product_savings = product_savings_for(orders)
    @total_supplier_savings = @product_savings.sum { |r| r[3].to_f }
    @missed_items = missed_savings_for(orders)
    @total_missed_savings = @missed_items.sum { |r| r[:total_potential_savings] }
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
    @monthly_trend = monthly_trend(orders)

    # Recent orders (last 10)
    @recent_orders = orders.order(created_at: :desc).limit(10)
                           .includes(:supplier, :location)

    @product_savings = product_savings_for(orders)
    @total_realized_savings = @product_savings.sum { |r| r[3].to_f }
    @missed_items = missed_savings_for(orders)
    @total_potential_savings = @missed_items.sum { |r| r[:total_potential_savings] }
  end

  def savings
    orders = filtered_orders
    @product_savings = product_savings_for(orders, limit: 50)
    @total_realized_savings = @product_savings.sum { |r| r[3].to_f }
  end

  def missed_savings
    org = current_user.current_organization
    promoted = AggregatedList.where(organization_id: org.id).promoted.first
    @has_matched_lists = promoted.present? ||
      AggregatedList.where(organization_id: org.id)
                    .where(location_id: accessible_locations.select(:id))
                    .matched_lists.any?

    orders = filtered_orders
    @missed_items = @has_matched_lists ? missed_savings_for(orders) : []
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

  # Grouping key that never collapses distinct products into one blank row:
  # order_items.product_name is NULL on bulk-inserted (builder) orders, which
  # merged 123 different products into a single unnamed row on the reports page.
  # Falls back to the live supplier product's name, then the SKU.
  ITEM_NAME_SQL = Arel.sql(
    "COALESCE(NULLIF(order_items.product_name, ''), " \
    "NULLIF(supplier_products.supplier_name, ''), " \
    "NULLIF(order_items.product_sku, ''), " \
    "'Unknown product (item ' || order_items.id || ')')"
  ).freeze

  def top_products(orders, limit: 20)
    OrderItem
      .joins(:order)
      .joins("LEFT JOIN supplier_products ON supplier_products.id = order_items.supplier_product_id")
      .where(orders: { id: orders.select(:id) })
      .group(ITEM_NAME_SQL)
      .order(Arel.sql("SUM(order_items.line_total) DESC"))
      .limit(limit)
      .pluck(
        ITEM_NAME_SQL,
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

  def monthly_trend(orders)
    six_months_ago = 6.months.ago.beginning_of_month.beginning_of_day
    data = orders.where("orders.created_at >= ?", six_months_ago)
      .group(Arel.sql("date_trunc('month', orders.created_at)"))
      .pluck(
        Arel.sql("date_trunc('month', orders.created_at)"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)")
      ).index_by { |row| row[0].to_date }

    (0..5).map do |months_ago|
      month_start = (Date.current - months_ago.months).beginning_of_month
      row = data[month_start]
      { month: month_start, label: month_start.strftime("%b %Y"), total: row ? row[1] : 0, count: row ? row[2] : 0 }
    end.reverse
  end

  # Per-product realized savings: what was paid vs the most expensive supplier alternative
  def product_savings_for(orders, limit: 15)
    OrderItem
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
      # Drop implausible lines (mirrors Order::MAX_SAVINGS_MULTIPLE): a peer
      # price many times what was paid is a data error, not a realized saving.
      .where(
        "(max_prices.max_price - order_items.unit_price) * order_items.quantity <= order_items.line_total * ?",
        Order::MAX_SAVINGS_MULTIPLE
      )
      .group(ITEM_NAME_SQL)
      .order(Arel.sql("SUM((max_prices.max_price - order_items.unit_price) * order_items.quantity) DESC"))
      .limit(limit)
      .pluck(
        ITEM_NAME_SQL,
        Arel.sql("SUM(order_items.line_total)"),
        Arel.sql("SUM(max_prices.max_price * order_items.quantity)"),
        Arel.sql("SUM((max_prices.max_price - order_items.unit_price) * order_items.quantity)"),
        Arel.sql("SUM(order_items.quantity)")
      )
  end

  # Products where a cheaper supplier alternative existed but wasn't chosen.
  #
  # Two things make this arithmetic delicate, and both were wrong until Aug 2026,
  # when the dashboard offered "$48.74 paid, $3.90 at Chef's Warehouse" — a case
  # price set against a per-LB one:
  #
  #   1. Peers must be compared as CASE-EQUIVALENTS. ProductMatch#cheapest_supplier
  #      already *ranks* on the case-equivalent, but the hash it returns also carries
  #      the raw scraped :price, which for catch-weight goods is $/LB. Both the math
  #      and the "their price" column read :estimated_price now.
  #   2. Savings are summed PER LINE rather than extrapolated from
  #      AVG(unit_price) x SUM(quantity) — one averaged spread applied to every unit
  #      ever bought overstates the total whenever prices moved between orders.
  #
  # A line claiming more than Order::MAX_SAVINGS_MULTIPLE x what was actually paid
  # is dropped as a data error, mirroring Order#line_savings_for.
  def missed_savings_for(orders)
    org = current_user.current_organization
    promoted = AggregatedList.where(organization_id: org.id).promoted.first
    agg_lists = if promoted
      AggregatedList.where(id: promoted.id)
    else
      AggregatedList.where(organization_id: org.id)
                    .where(location_id: accessible_locations.select(:id))
                    .matched_lists
    end

    return [] unless agg_lists.any?

    ordered_lines = OrderItem
      .joins(:order)
      .where(orders: { id: orders.select(:id) })
      .where.not(supplier_product_id: nil)
      .pluck(
        Arel.sql("order_items.supplier_product_id"),
        Arel.sql("order_items.product_name"),
        Arel.sql("order_items.unit_price"),
        Arel.sql("order_items.quantity"),
        Arel.sql("order_items.line_total")
      )

    return [] if ordered_lines.empty?

    lines_by_product = ordered_lines.group_by(&:first)
    match_items = ProductMatchItem
      .joins(:supplier_list_item)
      .where(supplier_list_items: { supplier_product_id: lines_by_product.keys })
      .where(product_match_id: agg_lists.joins(:product_matches).select("product_matches.id"))
      .includes(product_match: { product_match_items: [{ supplier_list_item: :supplier_product }, :supplier] })
      .index_by { |pmi| pmi.supplier_list_item.supplier_product_id }

    lines_by_product.filter_map do |sp_id, lines|
      pmi = match_items[sp_id]
      next unless pmi

      pm = pmi.product_match
      cheapest = pm.cheapest_supplier
      ordered_supplier = pmi.supplier
      next unless cheapest && cheapest[:supplier].id != ordered_supplier.id

      cheaper_price = cheapest_case_price(cheapest)
      next unless cheaper_price&.positive?

      qualifying = qualifying_lines(lines, cheaper_price)
      next if qualifying.empty?

      total_savings = qualifying.sum { |line| line[:savings] }
      total_qty = qualifying.sum { |line| line[:quantity] }
      total_paid = qualifying.sum { |line| line[:paid] }
      next unless total_savings.positive? && total_qty.positive?

      {
        product_name: lines.filter_map { |line| line[1] }.max,
        ordered_from: ordered_supplier.name,
        # Weighted by quantity, so a big line counts for more than a one-off.
        ordered_price: (total_paid / total_qty).round(2),
        cheaper_supplier: cheapest[:supplier].name,
        cheaper_price: cheaper_price.round(2),
        # True when the comparison price was derived from a per-unit price
        # (catch-weight) rather than quoted as a case — surfaced as "est." in the UI.
        cheaper_price_estimated: estimated_case_price?(cheapest),
        savings_per_order: (total_savings / total_qty).round(2),
        total_potential_savings: total_savings.round(2),
        total_qty: total_qty.round(1)
      }
    end.sort_by { |r| -r[:total_potential_savings] }
  end

  # The peer's full case cost. :estimated_price converts a catch-weight $/LB
  # quote to the case; it falls back to the raw price when no conversion applies.
  def cheapest_case_price(cheapest)
    (cheapest[:estimated_price] || cheapest[:price])&.to_f
  end

  def estimated_case_price?(cheapest)
    cheapest[:estimated_price].present? && cheapest[:price].present? &&
      cheapest[:estimated_price].to_f.round(2) != cheapest[:price].to_f.round(2)
  end

  # Per-line savings against one peer case price. Lines are dropped when the peer
  # isn't actually cheaper or when the claimed saving is implausible.
  #
  # Note this compares case to case, so a peer that is cheaper per ounce but sold
  # in a larger case yields nothing here — the table's columns ("price paid" vs
  # "their price") can't express "cheaper, but you must buy 20 lb instead of 10".
  # Under-reporting that case beats inventing savings the chef can't realize.
  def qualifying_lines(lines, cheaper_price)
    lines.filter_map do |_sp_id, _name, unit_price, quantity, line_total|
      paid_unit = unit_price.to_f
      qty = quantity.to_f
      paid = line_total.to_f
      next unless paid.positive? && qty.positive?
      next unless paid_unit > cheaper_price

      savings = (paid_unit - cheaper_price) * qty
      next if savings > paid * Order::MAX_SAVINGS_MULTIPLE

      { savings: savings, quantity: qty, paid: paid }
    end
  end
end
