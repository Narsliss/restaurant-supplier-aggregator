class DashboardController < ApplicationController
  def index
    # Super admin has no use for the regular dashboard — send to admin panel
    redirect_to admin_root_path and return if current_user.super_admin?

    # Onboarding takes priority — show setup wizard instead of dashboard
    if onboarding_incomplete?
      if chef?
        load_chef_onboarding_steps
      else
        load_onboarding_steps
      end
      return
    end

    # Keep showing the full-page wizard for owners who still have optional
    # steps (connect supplier, import lists) until they dismiss or complete.
    # This avoids the jarring jump from wizard → empty dashboard.
    if owner? && owner_setup_in_progress?
      load_onboarding_steps
      @required_steps_complete = true # enables "Go to Dashboard" dismiss button
      return
    end

    if owner?
      load_owner_dashboard
    elsif current_role == 'manager'
      load_manager_dashboard
    else
      load_chef_dashboard
    end
  end

  def dismiss_onboarding
    current_user.update_column(:onboarding_dismissed_at, Time.current)
    redirect_to root_path
  end

  private

  def load_owner_dashboard
    org = current_user.current_organization

    base_orders = scoped_orders
    kpi_orders = base_orders.kpi_eligible
    base_credentials = scoped_credentials

    @supplier_credentials = base_credentials
      .includes(:supplier, :user)
      .order(:created_at)

    @pending_2fa_requests = current_user.supplier_2fa_requests
      .pending
      .where("expires_at > ?", Time.current)
      .includes(supplier_credential: :supplier)

    # Stats with current + prior month for % change
    # Only count orders that were actually submitted to suppliers (kpi_eligible)
    month_start = Time.current.beginning_of_month
    prior_month_start = 1.month.ago.beginning_of_month
    prior_month_end = month_start - 1.second

    current_month_stats = kpi_orders.where("orders.created_at >= ?", month_start).pick(
      Arel.sql("COALESCE(SUM(total_amount), 0)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)"),
      Arel.sql("COUNT(*)")
    )
    prior_month_stats = kpi_orders.where(created_at: prior_month_start..prior_month_end).pick(
      Arel.sql("COALESCE(SUM(total_amount), 0)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)"),
      Arel.sql("COUNT(*)")
    )

    all_time_savings = kpi_orders.sum(:savings_amount) || 0

    @stats = {
      total_savings: all_time_savings,
      spend_this_month: current_month_stats[0],
      spend_change: percentage_change(current_month_stats[0], prior_month_stats[0]),
      savings_this_month: current_month_stats[1],
      savings_change: percentage_change(current_month_stats[1], prior_month_stats[1]),
      team_members: org&.member_count || 0,
      restaurants: org&.locations&.count || 0,
      active_suppliers: base_credentials.where(status: 'active').count
    }

    # Setup wizard (inline)
    @onboarding_steps = build_owner_setup_steps(org)
    @onboarding_complete = @onboarding_steps.all? { |s| s[:done] } || current_user.onboarding_dismissed_at?
    @onboarding_hard_gate = false

    # Weekly spending trend (8 weeks)
    @weekly_trend = load_weekly_trend(kpi_orders)

    # Team activity — orders per member this month
    member_rows = kpi_orders.where("orders.created_at >= ?", month_start)
      .group(:user_id)
      .pluck(
        Arel.sql("user_id"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(total_amount), 0)")
      )
    users_by_id = User.where(id: member_rows.map(&:first)).index_by(&:id)
    @team_activity = member_rows.map do |row|
      { user: users_by_id[row[0]], order_count: row[1], total_spent: row[2] }
    end.sort_by { |r| -r[:order_count] }

    # Restaurant performance — per-location this month
    locations = org&.locations || Location.none
    loc_stats = org.orders.kpi_eligible.where(location_id: locations.select(:id))
      .where("orders.created_at >= ?", month_start)
      .group(:location_id)
      .pluck(
        Arel.sql("location_id"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(savings_amount), 0)")
      ).index_by(&:first)

    @location_stats = locations.map do |loc|
      row = loc_stats[loc.id]
      {
        location: loc,
        monthly_spend: row ? row[1] : 0,
        order_count: row ? row[2] : 0,
        savings: row ? row[3] : 0
      }
    end.sort_by { |r| -r[:monthly_spend] }
  end

  def load_manager_dashboard
    base_orders = scoped_orders
    kpi_orders = base_orders.kpi_eligible
    base_credentials = scoped_credentials

    @recent_orders = base_orders
      .includes(:supplier, :location, :user)
      .order(created_at: :desc)
      .limit(10)

    @pending_2fa_requests = Supplier2faRequest.none

    # Stats with current + prior month for % change
    # Only count orders that were actually submitted to suppliers (kpi_eligible)
    month_start = Time.current.beginning_of_month
    prior_month_start = 1.month.ago.beginning_of_month
    prior_month_end = month_start - 1.second

    current_month_stats = kpi_orders.where("orders.created_at >= ?", month_start).pick(
      Arel.sql("COALESCE(SUM(total_amount), 0)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)"),
      Arel.sql("COUNT(*)"),
      Arel.sql("CASE WHEN COUNT(*) > 0 THEN ROUND(SUM(total_amount) / COUNT(*), 2) ELSE 0 END")
    )
    prior_month_stats = kpi_orders.where(created_at: prior_month_start..prior_month_end).pick(
      Arel.sql("COALESCE(SUM(total_amount), 0)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)"),
      Arel.sql("COUNT(*)"),
      Arel.sql("CASE WHEN COUNT(*) > 0 THEN ROUND(SUM(total_amount) / COUNT(*), 2) ELSE 0 END")
    )

    @stats = {
      spend_this_month: current_month_stats[0],
      spend_change: percentage_change(current_month_stats[0], prior_month_stats[0]),
      savings_this_month: current_month_stats[1],
      savings_change: percentage_change(current_month_stats[1], prior_month_stats[1]),
      orders_this_month: current_month_stats[2],
      orders_change: percentage_change(current_month_stats[2], prior_month_stats[2]),
      avg_order_value: current_month_stats[3],
      avg_order_change: percentage_change(current_month_stats[3], prior_month_stats[3])
    }

    # Weekly spending trend (8 weeks)
    @weekly_trend = load_weekly_trend(kpi_orders)

    # Spending by restaurant
    org = current_user.current_organization
    locations = accessible_locations
    loc_stats = kpi_orders.where("orders.created_at >= ?", month_start)
      .where(location_id: locations.select(:id))
      .group(:location_id)
      .pluck(
        Arel.sql("location_id"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(savings_amount), 0)")
      ).index_by(&:first)

    @location_stats = locations.map do |loc|
      row = loc_stats[loc.id]
      {
        location: loc,
        monthly_spend: row ? row[1] : 0,
        order_count: row ? row[2] : 0,
        savings: row ? row[3] : 0
      }
    end.sort_by { |r| -r[:monthly_spend] }

    # Spending by supplier
    supplier_rows = kpi_orders.where("orders.created_at >= ?", month_start)
      .group(:supplier_id)
      .pluck(
        Arel.sql("supplier_id"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(savings_amount), 0)")
      )
    suppliers_by_id = Supplier.where(id: supplier_rows.map(&:first)).index_by(&:id)
    @by_supplier = supplier_rows.map do |row|
      { supplier: suppliers_by_id[row[0]], total_spent: row[1], order_count: row[2], savings: row[3] }
    end.sort_by { |r| -r[:total_spent] }

    @read_only = true
  end

  def load_onboarding_steps
    org = current_user.current_organization
    @onboarding_steps = build_owner_setup_steps(org)
    @onboarding_complete = false # we know required steps are incomplete if we're here
    @onboarding_hard_gate = true # full-page wizard, no dashboard data
  end

  def load_chef_dashboard
    base_orders = scoped_orders
    base_credentials = scoped_credentials

    @pending_2fa_requests = current_user.supplier_2fa_requests
      .pending
      .where("expires_at > ?", Time.current)
      .includes(supplier_credential: :supplier)

    # Stats: orders this week, next delivery, pending verifications
    week_start = Time.current.beginning_of_week
    orders_this_week = base_orders.where("orders.created_at >= ?", week_start).count

    next_delivery_order = base_orders
      .where("delivery_date >= ?", Date.current)
      .where.not(status: %w[cancelled failed])
      .order(delivery_date: :asc)
      .includes(:supplier)
      .first

    pending_verification_count = base_orders
      .where(status: %w[verifying price_changed])
      .count

    @stats = {
      orders_this_week: orders_this_week,
      next_delivery: next_delivery_order,
      pending_verifications: pending_verification_count
    }

    # Upcoming deliveries — orders with future delivery dates, grouped by date
    @upcoming_deliveries = base_orders
      .where("delivery_date >= ?", Date.current)
      .where.not(status: %w[cancelled failed])
      .includes(:supplier, :order_items)
      .order(delivery_date: :asc)
      .limit(10)
      .group_by(&:delivery_date)

    # Daily order totals for the current week (bar chart)
    daily_data = base_orders.where("orders.created_at >= ?", week_start)
      .group(Arel.sql("DATE(orders.created_at)"))
      .pluck(
        Arel.sql("DATE(orders.created_at)"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)")
      ).index_by(&:first)

    @daily_orders = (0..6).map do |day_offset|
      day = week_start.to_date + day_offset.days
      row = daily_data[day]
      { date: day, label: day.strftime("%a"), total: row ? row[1] : 0, count: row ? row[2] : 0 }
    end

    # Recent orders
    @recent_orders = base_orders
      .includes(:supplier, :location)
      .order(created_at: :desc)
      .limit(8)

    # Getting-started cards for chefs
    org = current_user.current_organization
    @getting_started = [
      { title: "Connect a supplier", description: "Link your supplier account to pull in pricing and order guides", done: true, path: new_supplier_credential_path, cta: "Connect" },
      { title: "Import your order lists", description: "Pull in order guides and shopping lists from connected suppliers", done: scoped_supplier_lists.any?, path: supplier_lists_path, cta: "Import" }
    ]
    @getting_started = nil if @getting_started.all? { |s| s[:done] } || current_user.onboarding_dismissed_at?
  end

  # Owner has completed required steps (org, restaurant, team) but still has
  # optional steps (connect supplier, import lists) remaining. We keep the
  # full-page wizard visible so the setup flow feels continuous.
  def owner_setup_in_progress?
    return false if current_user.onboarding_dismissed_at?

    org = current_user.current_organization
    return false unless org

    steps = build_owner_setup_steps(org)
    !steps.all? { |s| s[:done] }
  end

  def chef_needs_onboarding?
    return false unless chef?

    org = current_user.current_organization
    return false unless org

    current_user.supplier_credentials.where(organization: org).none?
  end

  # Shared 4-step wizard for owners.
  # Steps 1-3 (create org, add restaurant, invite team) are required (hard gate).
  # Step 4 (connect supplier) is optional guidance. Order guides are imported
  # automatically when a supplier is connected, so no separate import step.
  def build_owner_setup_steps(org)
    @_owner_setup_steps ||= begin
    has_org = org.present?

    [
      {
        key: :create_org,
        title: "Create your organization",
        description: "Set up your restaurant group",
        done: has_org,
        path: new_organization_path,
        cta: "Create Organization",
        required: true
      },
      {
        key: :add_restaurant,
        title: "Add your first restaurant",
        description: "Add a delivery location so suppliers know where to ship",
        done: has_org && org.locations.any?,
        path: has_org ? new_location_path : "#",
        cta: "Add Restaurant",
        required: true
      },
      {
        key: :invite_team,
        title: "Invite your team",
        description: "Add managers and chefs to your organization",
        done: has_org && (org.memberships.where(active: true).count > 1 || org.organization_invitations.pending.any?),
        path: has_org ? organization_path : "#",
        cta: "Invite",
        required: true
      },
      {
        key: :connect_supplier,
        title: "Connect a supplier",
        description: current_location ?
          "Link your US Foods, Chef's Warehouse, or other supplier account — order guides will be imported automatically" :
          "Select a restaurant from the dropdown above, then connect your supplier account",
        done: has_org && org.supplier_credentials.where(status: 'active').any?,
        path: current_location ? new_supplier_credential_path : "#",
        cta: current_location ? "Connect" : nil,
        required: false
      }
    ]
    end
  end

  # Shared: 8-week spending trend bar chart data
  def load_weekly_trend(base_orders)
    eight_weeks_ago = 8.weeks.ago.beginning_of_week.beginning_of_day
    weekly_data = base_orders.where("orders.created_at >= ?", eight_weeks_ago)
      .group(Arel.sql("date_trunc('week', orders.created_at)"))
      .pluck(
        Arel.sql("date_trunc('week', orders.created_at)"),
        Arel.sql("COALESCE(SUM(total_amount), 0)"),
        Arel.sql("COUNT(*)")
      ).index_by { |row| row[0].to_date }

    (0..7).map do |weeks_ago|
      week_start = (Date.current - weeks_ago.weeks).beginning_of_week
      row = weekly_data[week_start]
      { week: week_start, label: week_start.strftime("%b %d"), total: row ? row[1] : 0, count: row ? row[2] : 0 }
    end.reverse
  end

  def percentage_change(current, previous)
    return nil if previous.nil? || previous.zero?
    ((current - previous).to_f / previous * 100).round(1)
  end

  def load_chef_onboarding_steps
    org = current_user.current_organization
    has_credentials = current_user.supplier_credentials.where(organization: org).any?

    @chef_onboarding_steps = [
      {
        key: :connect_supplier,
        title: "Connect a supplier account",
        description: "Link your US Foods, Chef's Warehouse, or other supplier login so we can pull in your order guides",
        done: has_credentials,
        path: new_supplier_credential_path,
        cta: "Connect Supplier",
        required: true
      }
    ]

    @chef_onboarding_complete = false
  end
end
