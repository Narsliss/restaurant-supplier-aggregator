class DashboardController < ApplicationController
  def index
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
    current_user.update!(onboarding_dismissed_at: Time.current)
    redirect_to root_path
  end

  private

  def load_owner_dashboard
    org = current_user.current_organization

    # Cache base relations to avoid rebuilding scoped queries multiple times
    base_orders = scoped_orders
    base_credentials = scoped_credentials
    base_order_lists = scoped_order_lists

    @recent_orders = base_orders
      .includes(:supplier, :location, :user)
      .order(created_at: :desc)
      .limit(10)

    @order_lists = base_order_lists
      .order(last_used_at: :desc, updated_at: :desc)
      .limit(5)

    @supplier_credentials = base_credentials
      .includes(:supplier, :user)
      .order(:created_at)

    @pending_2fa_requests = current_user.supplier_2fa_requests
      .pending
      .where("expires_at > ?", Time.current)
      .includes(supplier_credential: :supplier)

    # Combine order stats into fewer queries
    order_stats = base_orders.pick(
      Arel.sql("COUNT(*)"),
      Arel.sql("COUNT(CASE WHEN orders.created_at >= '#{Time.current.beginning_of_month.iso8601}' THEN 1 END)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)")
    )

    @stats = {
      total_orders: order_stats[0],
      orders_this_month: order_stats[1],
      active_suppliers: base_credentials.where(status: 'active').count,
      order_lists: base_order_lists.count,
      total_savings: order_stats[2],
      team_members: org&.member_count || 0,
      restaurants: org&.locations&.count || 0
    }

    # Setup wizard — same steps as the hard gate wizard, but shown inline
    # on the dashboard as optional guidance until all complete or dismissed
    @onboarding_steps = build_owner_setup_steps(org)
    @onboarding_complete = @onboarding_steps.all? { |s| s[:done] } || current_user.onboarding_dismissed_at?
    @onboarding_hard_gate = false

    # Per-restaurant breakdown — single grouped query instead of 2 queries per location
    locations = org&.locations || Location.none
    month_start = Time.current.beginning_of_month

    loc_counts = org.orders.where(location_id: locations.select(:id))
      .group(:location_id)
      .count
    loc_monthly = org.orders.where(location_id: locations.select(:id))
      .where("orders.created_at >= ?", month_start)
      .group(:location_id)
      .sum(:total_amount)

    @location_stats = locations.map do |loc|
      {
        location: loc,
        order_count: loc_counts[loc.id] || 0,
        monthly_spend: loc_monthly[loc.id] || 0
      }
    end
  end

  def load_manager_dashboard
    base_orders = scoped_orders
    base_credentials = scoped_credentials
    base_order_lists = scoped_order_lists

    @recent_orders = base_orders
      .includes(:supplier, :location, :user)
      .order(created_at: :desc)
      .limit(10)

    @order_lists = base_order_lists
      .order(last_used_at: :desc, updated_at: :desc)
      .limit(5)

    @supplier_credentials = base_credentials
      .includes(:supplier, :user)
      .order(:created_at)

    @pending_2fa_requests = Supplier2faRequest.none

    order_stats = base_orders.pick(
      Arel.sql("COUNT(*)"),
      Arel.sql("COUNT(CASE WHEN orders.created_at >= '#{Time.current.beginning_of_month.iso8601}' THEN 1 END)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)")
    )

    @stats = {
      total_orders: order_stats[0],
      orders_this_month: order_stats[1],
      active_suppliers: base_credentials.where(status: 'active').count,
      order_lists: base_order_lists.count,
      total_savings: order_stats[2]
    }

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
    base_order_lists = scoped_order_lists

    @recent_orders = base_orders
      .includes(:supplier, :location)
      .order(created_at: :desc)
      .limit(5)

    # Order lists are shared per-location — chef sees all lists at their restaurant
    @order_lists = base_order_lists
      .order(last_used_at: :desc, updated_at: :desc)
      .limit(5)

    @supplier_credentials = base_credentials
      .includes(:supplier)
      .order(:created_at)

    @pending_2fa_requests = current_user.supplier_2fa_requests
      .pending
      .where("expires_at > ?", Time.current)
      .includes(supplier_credential: :supplier)

    order_stats = base_orders.pick(
      Arel.sql("COUNT(*)"),
      Arel.sql("COUNT(CASE WHEN orders.created_at >= '#{Time.current.beginning_of_month.iso8601}' THEN 1 END)"),
      Arel.sql("COALESCE(SUM(savings_amount), 0)")
    )

    @stats = {
      total_orders: order_stats[0],
      orders_this_month: order_stats[1],
      active_suppliers: base_credentials.where(status: 'active').count,
      order_lists: base_order_lists.count,
      total_savings: order_stats[2]
    }

    # Getting-started cards for chefs (shown after at least one credential connected)
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
