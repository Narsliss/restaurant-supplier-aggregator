class EventPlansController < ApplicationController
  before_action :require_organization!
  before_action :set_event_plan, only: %i[show build_order finalize destroy]

  def index
    @event_plans = current_user.event_plans
      .where(organization: current_user.current_organization)
      .recent
  end

  def create
    @event_plan = current_user.event_plans.create!(
      organization: current_user.current_organization,
      status: "drafting"
    )
    redirect_to @event_plan
  end

  def show
    @messages = @event_plan.conversation_messages
  end

  def finalize
    @event_plan.update!(status: "finalized")
    redirect_to @event_plan, notice: "Menu finalized! Ready to build your order."
  end

  def destroy
    @event_plan.destroy!
    redirect_to event_plans_path, notice: "Event plan deleted."
  end

  def build_order
    unless @event_plan.has_menu?
      redirect_to @event_plan, alert: "Generate a menu first before building an order."
      return
    end

    service = EventPlanOrderService.new(
      event_plan: @event_plan,
      user: current_user,
      location: current_location
    )
    orders, batch_id = service.create_pending_orders!

    if orders.any?
      @event_plan.update!(status: "ordered")
      redirect_to review_orders_path(batch_id: batch_id)
    else
      redirect_to @event_plan, alert: "No ingredients could be matched to supplier products. Try refining your menu."
    end
  end

  private

  def set_event_plan
    @event_plan = current_user.event_plans
      .where(organization: current_user.current_organization)
      .find(params[:id])
  end
end
