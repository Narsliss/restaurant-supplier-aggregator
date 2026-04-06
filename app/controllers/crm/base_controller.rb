class Crm::BaseController < ApplicationController
  before_action :require_crm_access!

  skip_before_action :ensure_onboarding_complete, raise: false

  helper_method :current_crm_section

  private

  def require_crm_access!
    unless current_user&.salesperson? || current_user&.super_admin?
      redirect_to root_path, alert: "Not authorized"
    end
  end

  def current_crm_section
    controller_name
  end

end
