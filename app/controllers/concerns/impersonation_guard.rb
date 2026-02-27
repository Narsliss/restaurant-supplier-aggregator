module ImpersonationGuard
  extend ActiveSupport::Concern

  included do
    before_action :block_writes_while_impersonating
  end

  private

  def block_writes_while_impersonating
    return unless session[:impersonating]
    return if request.get? || request.head?
    return if devise_controller?
    return if controller_path == 'admin/users' && action_name == 'stop_impersonating'

    redirect_back fallback_location: root_path,
                  alert: "Read-only mode: actions are disabled while viewing as another user."
  end

  def impersonating?
    session[:impersonating].present?
  end
end
