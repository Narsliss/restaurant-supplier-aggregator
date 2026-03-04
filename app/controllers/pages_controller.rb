class PagesController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :ensure_onboarding_complete
  skip_before_action :require_subscription

  def terms; end
end
