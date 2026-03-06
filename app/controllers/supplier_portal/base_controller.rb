# Base controller for the Supplier Portal.
# Requires SupplierUser authentication (separate from User/Devise).
# All data is scoped to the current supplier — suppliers can only see their own data.
class SupplierPortal::BaseController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  skip_before_action :ensure_onboarding_complete, raise: false
  skip_before_action :require_subscription, raise: false

  before_action :authenticate_supplier_user!
  before_action :require_active_account!

  helper_method :current_supplier, :current_portal_section

  layout "supplier_portal"

  # Handle CSRF token expiry — redirect to supplier sign-in, not user sign-in
  rescue_from ActionController::InvalidAuthenticityToken do
    flash[:alert] = "Your session expired. Please sign in again."
    redirect_to new_supplier_user_session_path
  end

  private

  def current_supplier
    @current_supplier ||= current_supplier_user.supplier
  end

  def current_portal_section
    controller_name
  end

  def require_active_account!
    unless current_supplier_user.active?
      sign_out(current_supplier_user)
      redirect_to new_supplier_user_session_path, alert: "Your account has been deactivated. Please contact your administrator."
    end
  end

  # --- Privacy scoping helpers ---
  # Every query in the supplier portal MUST use these methods.
  # Suppliers can only see their own orders/products.

  def scoped_orders
    Order.where(supplier_id: current_supplier.id)
         .where(status: %w[submitted confirmed])
  end

  def scoped_products
    current_supplier.supplier_products
  end

  def scoped_order_items
    OrderItem.joins(:order)
             .where(orders: { supplier_id: current_supplier.id, status: %w[submitted confirmed] })
  end

  def scoped_incomplete_orders
    Order.where(supplier_id: current_supplier.id, status: %w[pending failed cancelled])
  end
end
