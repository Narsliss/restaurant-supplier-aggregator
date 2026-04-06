class Crm::CustomersController < Crm::BaseController
  def index
    @leads = Crm::Lead.includes(:organization, :onboarding, :tags)
                       .where.not(organization_id: nil)
                       .order(updated_at: :desc)
  end

  def show
    @lead = Crm::Lead.includes(:organization, :onboarding, :activities, :tags).find(params[:id])
    @organization = @lead.organization
    @onboarding = @lead.onboarding
    @activities = @lead.activities.recent.includes(:user)
    @orders = @organization&.orders&.order(created_at: :desc)&.limit(10) || []
  end
end
