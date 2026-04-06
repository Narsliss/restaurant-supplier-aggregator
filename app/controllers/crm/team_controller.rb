class Crm::TeamController < Crm::BaseController
  before_action :require_super_admin!
  before_action :set_user, only: [:edit, :update, :resend_welcome]

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
      SalespersonMailer.welcome(@user, params[:user][:password]).deliver_later
      redirect_to crm_team_index_path, notice: "Salesperson #{@user.full_name} created successfully. Welcome email sent."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def resend_welcome
    temp_password = SecureRandom.hex(4) # 8-character temporary password
    @user.update!(password: temp_password, password_confirmation: temp_password)
    SalespersonMailer.welcome(@user, temp_password).deliver_later
    redirect_to crm_team_index_path, notice: "Welcome email resent to #{@user.email} with a new temporary password."
  end

  def edit
  end

  def update
    update_params = salesperson_params.reject { |_, v| v.blank? }

    if @user.update(update_params)
      redirect_to crm_team_index_path, notice: "#{@user.full_name} updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def require_super_admin!
    redirect_to crm_root_path, alert: "Not authorized" unless current_user.super_admin?
  end

  def set_user
    @user = User.where(role: "salesperson").find(params[:id])
  end

  def salesperson_params
    params.require(:user).permit(:first_name, :last_name, :email, :phone, :password, :password_confirmation)
  end
end
