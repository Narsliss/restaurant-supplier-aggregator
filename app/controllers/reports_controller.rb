class ReportsController < ApplicationController
  before_action :require_organization!
  before_action :require_owner_or_manager!
  before_action :set_date_range

  helper_method :filter_params

  # Rows shown in the per-product breakdown on the savings page. The page's
  # headline total is NOT derived from these rows — see #realized_savings_total.
  PRODUCT_SAVINGS_ROWS = 50

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
    @total_realized_savings = realized_savings_total(orders)
    @savings_coverage = savings_coverage(orders)
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
    @total_supplier_savings = realized_savings_total(orders)
    @savings_coverage = savings_coverage(orders)
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
    @total_realized_savings = realized_savings_total(orders)
    @savings_coverage = savings_coverage(orders)
    @missed_items = missed_savings_for(orders)
    @total_potential_savings = @missed_items.sum { |r| r[:total_potential_savings] }
  end

  def savings
    orders = filtered_orders
    @total_realized_savings = realized_savings_total(orders)
    @savings_coverage = savings_coverage(orders)

    all_rows = product_savings_for(orders, limit: nil)
    @product_count = all_rows.size
    @product_savings = all_rows.first(PRODUCT_SAVINGS_ROWS)
    # Subtotals for the CURRENT-PRICE breakdown — a different basis from the
    # headline above, so they're labelled separately rather than summed together.
    @current_price_total = all_rows.sum { |r| r[3].to_f }
    @displayed_savings = @product_savings.sum { |r| r[3].to_f }
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

  # THE realized-savings figure — the per-order snapshot taken when each order was
  # placed, which is what "Total Savings" has always meant on the summary cards.
  #
  # Every screen showing a realized-savings headline reads it from here. They used
  # to sum whatever rows #product_savings_for happened to return, which was a
  # top-N slice recomputed against today's order guides: the savings page and the
  # summary card disagreed by $1,469 on the same date range, with nothing on
  # either page to say why. A per-product breakdown is a useful lens, but it is
  # not the total, and it must not be labelled as one.
  def realized_savings_total(orders)
    orders.sum(:savings_amount) || 0
  end

  # How much of the spend the savings figures could actually speak to. Shown
  # beside every total, because a dollar figure without its coverage invites the
  # reader to assume it covers everything.
  def savings_coverage(orders)
    items = OrderItem.where(order_id: orders.select(:id)).where.not(supplier_product_id: nil)
                     .includes(:supplier_product).to_a
    return { compared_lines: 0, total_lines: 0, compared_spend: 0, total_spend: 0 } if items.empty?

    peers = ComparisonCandidate.peers_for(items.filter_map(&:supplier_product))
    compared = items.select do |item|
      Orders::SavingsCalculator.call(item, peers[item.supplier_product_id] || []).comparable?
    end

    {
      compared_lines: compared.size,
      total_lines: items.size,
      compared_spend: compared.sum { |i| i.line_total.to_f }.round(2),
      total_spend: items.sum { |i| i.line_total.to_f }.round(2)
    }
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
  #   1. The peer's price has to be expressed as what they would charge for the
  #      SAME QUANTITY the chef actually buys. See #peer_equivalent_cost.
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
      .includes(product_match: { product_match_items: [{ supplier_list_item: [:supplier_product, :supplier_list] }, :supplier] })
      .index_by { |pmi| pmi.supplier_list_item.supplier_product_id }

    lines_by_product.filter_map do |sp_id, lines|
      pmi = match_items[sp_id]
      next unless pmi

      pm = pmi.product_match
      # Missed-savings is a dollar claim about a choice a chef made, so it is
      # only made where the suppliers' own units settled the comparison. A line
      # ranked through an estimated pack weight still shows its ranking on the
      # list; nobody gets told it cost them money on the strength of a weight
      # no supplier ever stated.
      next unless pm.comparison_verdict == :exact

      cheapest = pm.cheapest_supplier
      ordered_supplier = pmi.supplier
      next unless cheapest && cheapest[:supplier].id != ordered_supplier.id

      comparison = peer_equivalent_cost(pm, ordered_supplier, cheapest)
      next unless comparison

      qualifying = qualifying_lines(lines, comparison[:price])
      next if qualifying.empty?

      total_savings = qualifying.sum { |line| line[:savings] }
      total_qty = qualifying.sum { |line| line[:quantity] }
      total_paid = qualifying.sum { |line| line[:paid] }
      next unless total_savings.positive? && total_qty.positive?

      {
        product_name: lines.filter_map { |line| line[1] }.max,
        ordered_from: ordered_supplier.name,
        ordered_pack: pmi.supplier_list_item.pack_size,
        # Weighted by quantity, so a big line counts for more than a one-off.
        ordered_price: (total_paid / total_qty).round(2),
        cheaper_supplier: cheapest[:supplier].name,
        cheaper_price: comparison[:price].round(2),
        # Present when the price above is the peer's RATE applied to the ordered
        # case's size rather than their own case sticker — the UI shows both, because
        # realizing the saving means buying in their pack size.
        cheaper_rate: comparison[:rate],
        cheaper_pack: comparison[:pack],
        savings_per_order: (total_savings / total_qty).round(2),
        total_potential_savings: total_savings.round(2),
        total_qty: total_qty.round(1)
      }
    end.sort_by { |r| -r[:total_potential_savings] }
  end

  # What the cheaper supplier would charge for the SAME QUANTITY the chef buys in
  # one of their usual cases.
  #
  # Comparing case sticker to case sticker only works when both suppliers happen to
  # sell the same pack. When they don't — a $3.90/LB peer selling 40 lb cases against
  # the 81 oz case being bought — the honest figure is their rate applied to the
  # quantity ordered: $0.244/oz x 81 oz = $19.75. ProductMatch already computes that
  # shared $/oz basis (:comparison_metric) for the matched-list comparison UI; reusing
  # it keeps both screens agreeing on who is cheaper and by how much.
  #
  # Falls back to the peer's own case cost when there is no shared basis (mixed units
  # with no conversion), which is the best comparison available in that case.
  def peer_equivalent_cost(pm, ordered_supplier, cheapest)
    group = pm.per_unit_comparable? ? pm.comparable_group : []
    ordered_entry = group.find { |p| p[:supplier].id == ordered_supplier.id }
    peer_rate = cheapest[:comparison_metric].to_f
    units = ordered_entry && ordered_case_units(ordered_entry)

    if peer_rate.positive? && units && units.positive?
      return {
        price: peer_rate * units,
        rate: pm.display_per_unit_for(cheapest[:item]),
        pack: cheapest[:pack_size]
      }
    end

    price = (cheapest[:estimated_price] || cheapest[:price])&.to_f
    price&.positive? ? { price: price, rate: nil, pack: cheapest[:pack_size] } : nil
  end

  # How many normalized units (oz, fl oz, each) one ordered case holds. Derived by
  # dividing the case cost by its own per-unit rate — the price cancels out, so it
  # works both for exactly parsed packs and ProduceWeightEstimator's $/oz estimates.
  def ordered_case_units(entry)
    rate = entry[:comparison_metric].to_f
    case_cost = (entry[:estimated_price] || entry[:price]).to_f
    return nil unless rate.positive? && case_cost.positive?

    case_cost / rate
  end

  # Per-line savings against the peer's cost for one ordered case's worth. Lines are
  # dropped when the peer isn't actually cheaper or the claimed saving is implausible.
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
