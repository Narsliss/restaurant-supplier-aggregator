class ApplicationController < ActionController::Base
  include OrganizationAuthorization

  before_action :authenticate_user!
  before_action :ensure_onboarding_complete, unless: :skip_onboarding_check?
  # TODO: Re-enable subscription enforcement when ready for production
  # before_action :require_subscription, unless: :skip_subscription_check?
  before_action :configure_permitted_parameters, if: :devise_controller?

  helper_method :current_location, :subscription_required?, :onboarding_incomplete?, :viewing_all_locations?

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:first_name, :last_name, :phone])
    devise_parameter_sanitizer.permit(:account_update, keys: [:first_name, :last_name, :phone])
  end

  def current_location
    return @current_location if defined?(@current_location)

    # Owner explicitly chose "All Locations"
    if owner? && session[:current_location_id] == "all"
      @current_location = nil
      return @current_location
    end

    if session[:current_location_id].present?
      loc = accessible_locations.find_by(id: session[:current_location_id])
      @current_location = loc if loc
    end

    # Chefs always get their assigned restaurant
    @current_location ||= current_user.assigned_location if chef?

    # Everyone else (including owners with no explicit choice) gets first accessible location
    @current_location ||= current_user.default_location

    @current_location
  end

  # Owner is viewing "All Locations" aggregate mode (explicitly selected)
  def viewing_all_locations?
    owner? && session[:current_location_id] == "all"
  end

  def set_current_location(location)
    session[:current_location_id] = location&.id
    @current_location = location
  end

  def require_super_admin
    unless current_user&.super_admin?
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

  # Onboarding gate — new users must complete setup before using the rest of the app
  # Applies to: users with no org, or owners whose org is missing locations/suppliers
  def onboarding_incomplete?
    return false unless current_user
    return false if current_user.super_admin?

    org = current_user.current_organization
    return true unless org # no org yet — definitely incomplete

    # Only owners are gated; managers/chefs were invited so they're already set up
    return false unless owner?

    !org.locations.any?
  end

  def ensure_onboarding_complete
    return unless current_user
    return if current_user.super_admin?
    return unless onboarding_incomplete?

    redirect_to root_path
  end

  def skip_onboarding_check?
    devise_controller? ||
      controller_name == "dashboard" ||
      controller_name == "organizations" ||
      controller_name == "locations" ||
      controller_name == "supplier_credentials" ||
      controller_name == "subscriptions" ||
      controller_name == "invitations" ||
      controller_path.start_with?("webhooks") ||
      controller_name == "health"
  end
end
