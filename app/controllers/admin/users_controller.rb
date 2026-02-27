class Admin::UsersController < Admin::BaseController
  def index
    @users = User.where(role: 'user')
                 .includes(:current_organization)
                 .order(sort_column => sort_direction)

    # Search
    if params[:q].present?
      @users = @users.where('email ILIKE :q OR first_name ILIKE :q OR last_name ILIKE :q', q: "%#{params[:q]}%")
    end

    # Filters
    case params[:filter]
    when 'active'  then @users = @users.where('current_sign_in_at >= ?', 7.days.ago)
    when 'dormant' then @users = @users.where('current_sign_in_at < ? OR current_sign_in_at IS NULL', 30.days.ago)
    when 'locked'  then @users = @users.where.not(locked_at: nil)
    end

    @page = (params[:page] || 1).to_i
    @per_page = 25
    @total_count = @users.count
    @users = @users.offset((@page - 1) * @per_page).limit(@per_page)
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
    admin = User.find(session[:admin_user_id])
    impersonated_user_id = session[:impersonated_user_id]
    session.delete(:admin_user_id)
    session.delete(:impersonated_user_id)
    session.delete(:impersonating)
    sign_in(:user, admin)
    redirect_to admin_user_path(impersonated_user_id), notice: "Stopped viewing as another user."
  end

  private

  def sort_column
    %w[created_at email sign_in_count current_sign_in_at].include?(params[:sort]) ? params[:sort] : 'created_at'
  end

  def sort_direction
    params[:direction] == 'asc' ? :asc : :desc
  end
end
