# Base controller for all admin pages.
# Requires super_admin role and skips organization-level checks
# since the admin is not scoped to any specific org.
class Admin::BaseController < ApplicationController
  before_action :require_super_admin

  # Super admin has no org/location context — skip these checks
  skip_before_action :ensure_onboarding_complete, raise: false

  helper_method :current_admin_section

  private

  def current_admin_section
    controller_name
  end
end
