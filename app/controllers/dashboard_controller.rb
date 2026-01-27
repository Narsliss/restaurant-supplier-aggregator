class DashboardController < ApplicationController
  def index
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
      order_lists: current_user.order_lists.count
    }
  end
end
