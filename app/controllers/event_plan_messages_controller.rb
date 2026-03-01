class EventPlanMessagesController < ApplicationController
  MAX_MESSAGE_LENGTH = 2_000

  before_action :require_organization!
  before_action :set_event_plan

  def create
    content = params[:content].to_s.strip

    if content.blank?
      respond_to do |format|
        format.turbo_stream { head :unprocessable_entity }
        format.html { redirect_to @event_plan, alert: "Message cannot be blank." }
      end
      return
    end

    if content.length > MAX_MESSAGE_LENGTH
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.append("message-list",
            "<div class='text-center py-3 text-sm text-amber-600 dark:text-amber-400'>Message is too long (#{content.length} characters). Please keep messages under #{MAX_MESSAGE_LENGTH} characters.</div>".html_safe)
        end
        format.html { redirect_to @event_plan, alert: "Message is too long. Please keep it under #{MAX_MESSAGE_LENGTH} characters." }
      end
      return
    end

    unless @event_plan.can_send_message?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.append("message-list",
            "<div class='text-center py-3 text-sm text-amber-600 dark:text-amber-400'>Message limit reached (#{@event_plan.message_limit} messages per plan). Start a new event plan to continue planning.</div>".html_safe)
        end
        format.html { redirect_to @event_plan, alert: "Message limit reached for this plan." }
      end
      return
    end

    @message = @event_plan.messages.create!(
      role: "user",
      content: content,
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
