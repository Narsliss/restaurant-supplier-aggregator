class EventPlansController < ApplicationController
  before_action :require_organization!
  before_action :set_event_plan, only: %i[show update build_order destroy]

  def index
    @org = current_user.current_organization
    @event_plans = current_user.event_plans
      .where(organization: @org)
      .recent
  end

  def create
    org = current_user.current_organization
    unless org.can_create_menu_plan?
      redirect_to event_plans_path,
        alert: "You've reached your monthly limit of #{org.menu_plan_monthly_limit} menu plans. Your quota resets #{distance_of_time_in_words_to_now(Time.current.end_of_month)} from now."
      return
    end

    @event_plan = current_user.event_plans.create!(
      organization: org,
      status: "drafting"
    )
    redirect_to @event_plan
  end

  def show
    @messages = @event_plan.conversation_messages
  end

  def update
    if @event_plan.update(event_plan_params)
      respond_to do |format|
        format.json { render json: { title: @event_plan.title }, status: :ok }
        format.html { redirect_to @event_plan, notice: "Plan updated." }
      end
    else
      respond_to do |format|
        format.json { render json: { error: @event_plan.errors.full_messages }, status: :unprocessable_entity }
        format.html { redirect_to @event_plan, alert: "Could not update plan." }
      end
    end
  end

  def destroy
    @event_plan.soft_delete!
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
    orders, batch_id, order_list = service.create_pending_orders!

    if orders.any?
      flash[:notice] = "Orders created! An order list \"#{order_list&.name}\" has also been saved so you can add items."
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

  def event_plan_params
    params.require(:event_plan).permit(:title)
  end
end
