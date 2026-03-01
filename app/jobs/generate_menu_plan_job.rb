class GenerateMenuPlanJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(event_plan_id, _msg_id, _thinking_id) { "menu_plan_#{event_plan_id}" }

  def perform(event_plan_id, user_message_id, thinking_message_id)
    event_plan = EventPlan.find(event_plan_id)
    user_message = EventPlanMessage.find(user_message_id)
    thinking_message = EventPlanMessage.find(thinking_message_id)

    result = MenuPlannerService.new(
      event_plan: event_plan,
      user_message: user_message.content
    ).call

    # Update the thinking message with the real response
    thinking_message.update!(
      content: result[:display_content],
      structured_data: result[:structured_data] || {},
      status: result[:error] ? "error" : "complete"
    )

    # Broadcast the updated message via Turbo Streams
    Turbo::StreamsChannel.broadcast_replace_to(
      event_plan,
      target: ActionView::RecordIdentifier.dom_id(thinking_message),
      partial: "event_plan_messages/message",
      locals: { message: thinking_message }
    )

    # Broadcast updated header (title, details bar, action buttons)
    event_plan.reload
    Turbo::StreamsChannel.broadcast_replace_to(
      event_plan,
      target: "event-plan-header",
      partial: "event_plans/header",
      locals: { event_plan: event_plan }
    )
  rescue => e
    Rails.logger.error "[GenerateMenuPlanJob] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"

    # Update the thinking message to show the error
    thinking_message = EventPlanMessage.find_by(id: thinking_message_id)
    if thinking_message
      thinking_message.update!(
        content: "Something went wrong generating the menu. Please try again.",
        status: "error"
      )

      event_plan = EventPlan.find_by(id: event_plan_id)
      if event_plan
        Turbo::StreamsChannel.broadcast_replace_to(
          event_plan,
          target: ActionView::RecordIdentifier.dom_id(thinking_message),
          partial: "event_plan_messages/message",
          locals: { message: thinking_message }
        )
      end
    end
  end
end
