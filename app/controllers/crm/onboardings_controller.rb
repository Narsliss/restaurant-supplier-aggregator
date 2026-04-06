class Crm::OnboardingsController < Crm::BaseController
  before_action :set_onboarding, only: [:show, :edit, :update]

  def index
    @onboardings = Crm::Onboarding.includes(:lead, :organization).order(created_at: :desc)
    @onboardings = @onboardings.where(stage: params[:stage]) if params[:stage].present?
    @onboardings = @onboardings.where(health_score: params[:health]) if params[:health].present?
  end

  def show
    @lead = @onboarding.lead
    @organization = @onboarding.organization
  end

  def edit
    @lead = @onboarding.lead
  end

  def update
    if @onboarding.update(onboarding_params)
      redirect_to crm_onboarding_path(@onboarding), notice: "Onboarding updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_onboarding
    @onboarding = Crm::Onboarding.find(params[:id])
  end

  def onboarding_params
    params.require(:crm_onboarding).permit(
      :stage, :health_score, :notes,
      :signed_up_at, :account_setup_at, :suppliers_connected_at, :first_order_at,
      :check_in_14_at, :check_in_30_at, :check_in_60_at, :check_in_90_at
    )
  end
end
