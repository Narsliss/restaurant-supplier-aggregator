class ApplicationController < ActionController::Base
  include OrganizationAuthorization
  include ImpersonationGuard

  before_action :set_mobile_variant
  before_action :authenticate_user!
  before_action :redirect_salesperson_to_crm
  before_action :ensure_onboarding_complete, unless: :skip_onboarding_check?
  before_action :require_subscription, unless: :skip_subscription_check?
  before_action :configure_permitted_parameters, if: :devise_controller?

  helper_method :current_location, :subscription_required?, :onboarding_incomplete?, :viewing_all_locations?, :impersonating?, :mobile?,
                :onboarding_wizard_visible?, :onboarding_wizard_progress

  # Show a helpful message when CSRF token is stale (e.g. after server restart or long idle)
  rescue_from ActionController::InvalidAuthenticityToken do
    flash[:alert] = "Your session expired. Please try again."
    redirect_to new_user_session_path
  end

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

  # Salesperson users have no business in the regular app — bounce to CRM
  def redirect_salesperson_to_crm
    return unless current_user&.salesperson?
    return if controller_path.start_with?("crm")
    return if devise_controller?
    return if controller_name == "health"

    redirect_to crm_root_path
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
      controller_name == "organizations" ||    # onboarding: create org
      controller_name == "locations" ||         # onboarding: add restaurant
      controller_name == "invitations" ||       # onboarding: invite team
      controller_name == "dashboard" ||         # onboarding landing page
      controller_path.start_with?("webhooks") ||
      controller_path.start_with?("admin") ||  # super admin panel
      controller_path.start_with?("crm") ||    # CRM sales pipeline
      controller_path.start_with?("supplier_portal") || # supplier portal
      controller_name == "health"
  end

  def subscription_required?
    !skip_subscription_check?
  end

  # Onboarding gate — new users must complete setup before using the rest of the app
  #
  # Owners:  1) create org, 2) add restaurant, 3) invite at least one team member
  # Chefs:   1) connect at least one supplier credential
  # Managers: no gate (they can view data immediately)
  def onboarding_incomplete?
    return false unless current_user
    return false if current_user.super_admin?

    org = current_user.current_organization
    return true unless org # no org yet — definitely incomplete

    # Chefs must connect at least one supplier before using the app
    if chef?
      return current_user.supplier_credentials.where(organization: org).none?
    end

    # Only owners are gated beyond this point
    return false unless owner?

    # Must have at least one restaurant
    return true unless org.locations.any?

    # Must have invited at least one team member (pending invite counts)
    has_team = org.memberships.where(active: true).count > 1 ||
               org.organization_invitations.pending.any?
    !has_team
  end

  def ensure_onboarding_complete
    return unless current_user
    return if current_user.super_admin?
    return unless onboarding_incomplete?

    redirect_to root_path
  end

  def set_mobile_variant
    if Rails.env.development? && params[:mobile] == "1"
      request.variant = :mobile
    elsif request.user_agent =~ /Mobile|Android|webOS|iPhone|iPod|BlackBerry|Opera Mini|IEMobile/i
      request.variant = :mobile
    end
  end

  def mobile?
    request.variant&.include?(:mobile)
  end

  # --- Onboarding wizard (spotlight tour) helpers ---
  #
  # These are read-only on every page render. The wizard's progress record
  # is lazily created the first time the user advances or skips a step
  # (server side, by Onboarding::ProgressController) — not here.

  def onboarding_wizard_progress
    return @onboarding_wizard_progress if defined?(@onboarding_wizard_progress)

    @onboarding_wizard_progress = if current_user
                                    OnboardingProgress.for_user(current_user)
                                  end
  end

  # Renders the turbo-frame chunk that signals "form saved successfully"
  # to the wizard's Stimulus controller. Used by org/restaurant/team form
  # controllers when params[:from_wizard] is present:
  #   render html: onboarding_wizard_form_marker_html("Saved"), layout: false
  def onboarding_wizard_form_marker_html(message = "Saved")
    safe_message = ERB::Util.html_escape(message)
    <<~HTML.html_safe
      <turbo-frame id="onboarding-step-form">
        <div data-onboarding-form-saved="true"
             class="onboarding-panel-step-form-saved">
          <span class="text-sm text-green-700 font-medium">✓ #{safe_message}</span>
        </div>
      </turbo-frame>
    HTML
  end

  def onboarding_wizard_visible?
    return false unless current_user
    return false if mobile?              # desktop-only in v1
    return false if devise_controller?

    progress = onboarding_wizard_progress
    return false unless progress

    # Owners with incomplete setup get the legacy fullscreen wizard (which
    # walks them through org/restaurant/team creation). Suppress the
    # spotlight tour while that's running.
    #
    # Chefs and managers don't have a fullscreen — the spotlight wizard's
    # supplier picker IS the chef's path to satisfying their "connect a
    # supplier" hard-gate, so we let it render right away.
    return false if onboarding_incomplete? && progress.role == "owner"

    progress.in_progress?
  end

  def skip_onboarding_check?
    devise_controller? ||
      controller_name == "dashboard" ||
      controller_name == "organizations" ||
      controller_name == "locations" ||
      controller_name == "supplier_credentials" ||
      controller_name == "email_suppliers" ||
      controller_name == "inbound_price_lists" ||
      controller_name == "subscriptions" ||
      controller_name == "invitations" ||
      controller_path.start_with?("webhooks") ||
      controller_path.start_with?("crm") ||            # CRM sales pipeline
      controller_path.start_with?("supplier_portal") || # supplier portal
      controller_name == "health"
  end
end
