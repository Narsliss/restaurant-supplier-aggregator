class Admin::UsersController < Admin::BaseController
  skip_before_action :require_super_admin, only: [:stop_impersonating]
  before_action :require_impersonation_session, only: [:stop_impersonating]

  def index
    redirect_to admin_organizations_path, status: :moved_permanently
  end

  def show
    @user = User.find(params[:id])
    @memberships = @user.memberships.includes(:organization).order(created_at: :desc)
    @credentials = @user.supplier_credentials.includes(:supplier, :organization).order(created_at: :desc)
    @recent_orders = @user.orders.includes(:supplier, :organization).order(created_at: :desc).limit(10)
  end

  def unlock
    user = User.find(params[:id])
    user.unlock_access!
    redirect_to admin_user_path(user), notice: "#{user.full_name}'s account has been unlocked."
  end

  def reset_password
    user = User.find(params[:id])
    user.send_reset_password_instructions
    redirect_to admin_user_path(user), notice: "Password reset email sent to #{user.email}."
  end

  def impersonate
    user = User.find(params[:id])
    session[:admin_user_id] = current_user.id
    session[:impersonated_user_id] = user.id
    session[:impersonating] = true
    sign_in(:user, user)
    redirect_to root_path, notice: "You are now viewing as #{user.full_name}. All actions are read-only."
  end

  def stop_impersonating
    admin = User.find_by(id: session[:admin_user_id])
    impersonated_user_id = session[:impersonated_user_id]
    session.delete(:admin_user_id)
    session.delete(:impersonated_user_id)
    session.delete(:impersonating)

    if admin&.super_admin?
      sign_in(:user, admin)
      redirect_to admin_user_path(impersonated_user_id), notice: "Stopped viewing as another user."
    else
      redirect_to root_path, alert: "Could not restore admin session."
    end
  end

  private

  def sort_column
    %w[created_at email sign_in_count current_sign_in_at].include?(params[:sort]) ? params[:sort] : 'created_at'
  end

  def sort_direction
    params[:direction] == 'asc' ? :asc : :desc
  end

  def require_impersonation_session
    unless session[:impersonating] && session[:admin_user_id]
      redirect_to root_path
    end
  end
end
