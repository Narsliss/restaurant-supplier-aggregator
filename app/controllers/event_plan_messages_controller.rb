class EventPlanMessagesController < ApplicationController
  before_action :require_organization!
  before_action :set_event_plan

  def create
    @message = @event_plan.messages.create!(
      role: "user",
      content: params[:content],
      status: "complete"
    )

    # Create a placeholder "thinking" message that will be replaced by the job
    @thinking = @event_plan.messages.create!(
      role: "assistant",
      content: "Generating your menu plan...",
      status: "thinking"
    )

    GenerateMenuPlanJob.perform_later(@event_plan.id, @message.id, @thinking.id)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @event_plan }
    end
  end

  private

  def set_event_plan
    @event_plan = current_user.event_plans
      .where(organization: current_user.current_organization)
      .find(params[:event_plan_id])
  end
end
