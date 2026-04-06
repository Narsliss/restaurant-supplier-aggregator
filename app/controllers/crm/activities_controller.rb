class Crm::ActivitiesController < Crm::BaseController
  before_action :set_lead
  before_action :set_activity, only: [:edit, :update, :destroy]

  def create
    @activity = @lead.activities.build(activity_params)
    @activity.user = current_user
    @activity.occurred_at ||= Time.current

    if @activity.save
      redirect_to crm_lead_path(@lead), notice: "Activity logged."
    else
      redirect_to crm_lead_path(@lead), alert: "Could not log activity."
    end
  end

  def edit
  end

  def update
    if @activity.update(activity_params)
      redirect_to crm_lead_path(@lead), notice: "Activity updated."
    else
      redirect_to crm_lead_path(@lead), alert: "Could not update activity."
    end
  end

  def destroy
    @activity.destroy
    redirect_to crm_lead_path(@lead), notice: "Activity removed."
  end

  private

  def set_lead
    @lead = Crm::Lead.find(params[:lead_id])
  end

  def set_activity
    @activity = @lead.activities.find(params[:id])
  end

  def activity_params
    params.require(:crm_activity).permit(:activity_type, :subject, :body, :occurred_at)
  end
end
