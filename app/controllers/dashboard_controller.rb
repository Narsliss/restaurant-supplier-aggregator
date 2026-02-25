class DashboardController < ApplicationController
  def index
    # Onboarding takes priority — show setup wizard instead of dashboard
    if onboarding_incomplete?
      load_onboarding_steps
      return
    end

    if owner?
      load_owner_dashboard
    elsif current_role == 'manager'
      load_manager_dashboard
    elsif chef_needs_onboarding?
      load_chef_onboarding_steps
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
    @recent_orders = scoped_orders
      .includes(:supplier, :location, :user)
      .order(created_at: :desc)
      .limit(10)

    @order_lists = scoped_order_lists
      .order(last_used_at: :desc, updated_at: :desc)
      .limit(5)

    @supplier_credentials = scoped_credentials
      .includes(:supplier, :user)
      .order(:created_at)

    @pending_2fa_requests = current_user.supplier_2fa_requests
      .pending
      .where("expires_at > ?", Time.current)
      .includes(supplier_credential: :supplier)

    @stats = {
      total_orders: scoped_orders.count,
      orders_this_month: scoped_orders.where("orders.created_at >= ?", Time.current.beginning_of_month).count,
      active_suppliers: scoped_credentials.where(status: 'active').count,
      order_lists: scoped_order_lists.count,
      total_savings: scoped_orders.sum(:savings_amount),
      team_members: org&.member_count || 0,
      restaurants: org&.locations&.count || 0
    }

    # Optional getting-started steps (shown until all complete)
    @getting_started = [
      { title: "Connect a supplier", description: "Link your US Foods, Chef's Warehouse, or other supplier account", done: org.supplier_credentials.where(status: 'active').any?, path: new_supplier_credential_path, cta: "Connect" },
      { title: "Import your order lists", description: "Pull in order guides and shopping lists from connected suppliers", done: org.supplier_lists.any?, path: supplier_lists_path, cta: "Import" },
      { title: "Invite your team", description: "Add managers and chefs to your organization", done: org.memberships.where(active: true).count > 1 || org.organization_invitations.pending.any?, path: organization_path, cta: "Invite" }
    ]
    @getting_started = nil if @getting_started.all? { |s| s[:done] } || current_user.onboarding_dismissed_at?

    # Per-restaurant breakdown for owners
    @location_stats = org&.locations&.map do |loc|
      {
        location: loc,
        order_count: org.orders.for_location(loc).count,
        monthly_spend: org.orders.for_location(loc)
          .where("orders.created_at >= ?", Time.current.beginning_of_month)
          .sum(:total_amount)
      }
    end || []
  end

  def load_manager_dashboard
    @recent_orders = scoped_orders
      .includes(:supplier, :location, :user)
      .order(created_at: :desc)
      .limit(10)

    @order_lists = scoped_order_lists
      .order(last_used_at: :desc, updated_at: :desc)
      .limit(5)

    @supplier_credentials = scoped_credentials
      .includes(:supplier, :user)
      .order(:created_at)

    @pending_2fa_requests = Supplier2faRequest.none

    @stats = {
      total_orders: scoped_orders.count,
      orders_this_month: scoped_orders.where("orders.created_at >= ?", Time.current.beginning_of_month).count,
      active_suppliers: scoped_credentials.where(status: 'active').count,
      order_lists: scoped_order_lists.count,
      total_savings: scoped_orders.sum(:savings_amount)
    }

    @read_only = true
  end

  def load_onboarding_steps
    org = current_user.current_organization
    has_org = org.present?

    @onboarding_steps = [
      {
        key: :create_org,
        title: "Create your organization",
        description: "Set up your restaurant group",
        done: has_org,
        path: new_organization_path,
        cta: "Create Organization"
      },
      {
        key: :add_restaurant,
        title: "Add your first restaurant",
        description: "Add a delivery location so suppliers know where to ship",
        done: has_org && org.locations.any?,
        path: has_org ? new_location_path : "#",
        cta: "Add Restaurant"
      }
    ]

    @onboarding_complete = false # we know it's incomplete if we're here
  end

  def load_chef_dashboard
    @recent_orders = scoped_orders
      .includes(:supplier, :location)
      .order(created_at: :desc)
      .limit(5)

    # Order lists are shared per-location — chef sees all lists at their restaurant
    @order_lists = scoped_order_lists
      .order(last_used_at: :desc, updated_at: :desc)
      .limit(5)

    @supplier_credentials = scoped_credentials
      .includes(:supplier)
      .order(:created_at)

    @pending_2fa_requests = current_user.supplier_2fa_requests
      .pending
      .where("expires_at > ?", Time.current)
      .includes(supplier_credential: :supplier)

    @stats = {
      total_orders: scoped_orders.count,
      orders_this_month: scoped_orders.where("orders.created_at >= ?", Time.current.beginning_of_month).count,
      active_suppliers: scoped_credentials.where(status: 'active').count,
      order_lists: scoped_order_lists.count,
      total_savings: scoped_orders.sum(:savings_amount)
    }

    # Getting-started cards for chefs (shown after at least one credential connected)
    org = current_user.current_organization
    @getting_started = [
      { title: "Connect a supplier", description: "Link your supplier account to pull in pricing and order guides", done: true, path: new_supplier_credential_path, cta: "Connect" },
      { title: "Import your order lists", description: "Pull in order guides and shopping lists from connected suppliers", done: scoped_supplier_lists.any?, path: supplier_lists_path, cta: "Import" }
    ]
    @getting_started = nil if @getting_started.all? { |s| s[:done] } || current_user.onboarding_dismissed_at?
  end

  def chef_needs_onboarding?
    return false unless chef?

    org = current_user.current_organization
    return false unless org

    current_user.supplier_credentials.where(organization: org).none?
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
        cta: "Connect Supplier"
      },
      {
        key: :import_lists,
        title: "Import your order lists",
        description: "Pull in your order guides and saved lists from connected suppliers",
        done: has_credentials && scoped_supplier_lists.any?,
        path: supplier_lists_path,
        cta: "Import Lists"
      }
    ]

    @chef_onboarding_complete = false
  end
end
