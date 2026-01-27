class ApplicationController < ActionController::Base
  before_action :authenticate_user!
  before_action :configure_permitted_parameters, if: :devise_controller?

  helper_method :current_location

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:first_name, :last_name, :phone])
    devise_parameter_sanitizer.permit(:account_update, keys: [:first_name, :last_name, :phone])
  end

  def current_location
    return @current_location if defined?(@current_location)
    
    @current_location = if session[:current_location_id]
      current_user.locations.find_by(id: session[:current_location_id])
    end
    @current_location ||= current_user.default_location
  end

  def set_current_location(location)
    session[:current_location_id] = location&.id
    @current_location = location
  end

  def require_admin!
    unless current_user&.admin?
      flash[:alert] = "You are not authorized to access this page."
      redirect_to root_path
    end
  end
end
