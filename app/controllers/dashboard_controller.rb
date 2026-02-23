class DashboardController < ApplicationController
  def index
    if owner?
      load_owner_dashboard
    elsif current_role == 'manager'
      load_manager_dashboard
    else
      load_chef_dashboard
    end
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

  def load_chef_dashboard
    @recent_orders = current_user.orders
      .includes(:supplier, :location)
      .order(created_at: :desc)
      .limit(5)

    @order_lists = current_user.order_lists
      .order(last_used_at: :desc, updated_at: :desc)
      .limit(5)

    @supplier_credentials = current_user.supplier_credentials
      .includes(:supplier)
      .order(:created_at)

    @pending_2fa_requests = current_user.supplier_2fa_requests
      .pending
      .where("expires_at > ?", Time.current)
      .includes(supplier_credential: :supplier)

    @stats = {
      total_orders: current_user.orders.count,
      orders_this_month: current_user.orders.where("created_at >= ?", Time.current.beginning_of_month).count,
      active_suppliers: current_user.supplier_credentials.active.count,
      order_lists: current_user.order_lists.count,
      total_savings: current_user.orders.sum(:savings_amount)
    }
  end
end
