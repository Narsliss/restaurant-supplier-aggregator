# Base controller for all admin pages.
# Open to the super admin and to admins (support staff). Actions that only the
# super admin may take add `before_action :require_super_admin, only: [...]`
# in their own controller. See docs/admin-role.md.
# Skips organization-level checks since neither is scoped to an org.
class Admin::BaseController < ApplicationController
  before_action :require_admin_access

  # No org/location context here — skip these checks
  skip_before_action :ensure_onboarding_complete, raise: false
end
