class Crm::TeamController < Crm::BaseController
  before_action :require_super_admin!

  def index
    @salespeople = User.where(role: "salesperson").order(created_at: :desc)
  end

  def new
    @user = User.new(role: "salesperson")
  end

  def create
    @user = User.new(salesperson_params)
    @user.role = "salesperson"

    if @user.save
      redirect_to crm_team_index_path, notice: "Salesperson #{@user.full_name} created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def require_super_admin!
    redirect_to crm_root_path, alert: "Not authorized" unless current_user.super_admin?
  end

  def salesperson_params
    params.require(:user).permit(:first_name, :last_name, :email, :phone, :password, :password_confirmation)
  end
end
