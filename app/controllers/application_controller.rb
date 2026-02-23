class ApplicationController < ActionController::Base
  include OrganizationAuthorization

  before_action :authenticate_user!
  # TODO: Re-enable subscription enforcement when ready for production
  # before_action :require_subscription, unless: :skip_subscription_check?
  before_action :configure_permitted_parameters, if: :devise_controller?

  helper_method :current_location, :subscription_required?

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:first_name, :last_name, :phone])
    devise_parameter_sanitizer.permit(:account_update, keys: [:first_name, :last_name, :phone])
  end

  def current_location
    return @current_location if defined?(@current_location)

    if session[:current_location_id]
      loc = accessible_locations.find_by(id: session[:current_location_id])
      @current_location = loc if loc
    end

    # Chefs always get their assigned restaurant
    @current_location ||= current_user.assigned_location if chef?

    # Fallback to first accessible location
    @current_location ||= current_user.default_location
  end

  def set_current_location(location)
    session[:current_location_id] = location&.id
    @current_location = location
  end

  def require_super_admin
    unless current_user&.super_admin?
      flash[:alert] = "You are not authorized to access this page."
      redirect_to root_path
    end
  end

  # Subscription enforcement
  def require_subscription
    return unless current_user
    return if current_user.subscribed?

    # Allow super_admins to bypass subscription check
    return if current_user.super_admin?

    # Redirect to subscription page
    flash[:alert] = "Please subscribe to access SupplierHub."
    redirect_to new_subscription_path
  end

  def skip_subscription_check?
    devise_controller? ||
      controller_name == "subscriptions" ||
      controller_path.start_with?("webhooks") ||
      controller_name == "health"
  end

  def subscription_required?
    !skip_subscription_check?
  end
end
