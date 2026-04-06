class Crm::DashboardController < Crm::BaseController
  def index
    @leads = Crm::Lead.all
    @leads = @leads.for_salesperson(User.find(params[:salesperson_id])) if params[:salesperson_id].present?

    @salespeople = User.where(role: "salesperson").order(:first_name) if current_user.super_admin?

    @active_leads = @leads.open_deals.count
    @pipeline_value = @leads.open_deals.sum(:deal_value_cents)
    @tasks_due_today = Crm::Task.pending.where(due_date: Date.current).count
    @overdue_tasks = Crm::Task.overdue.count
    @won_this_month = @leads.in_stage("closed_won").where("closed_at >= ?", Date.current.beginning_of_month).count
    @lost_this_month = @leads.in_stage("closed_lost").where("closed_at >= ?", Date.current.beginning_of_month).count

    @leads_by_stage = Crm::Lead::PIPELINE_STAGES.index_with do |stage|
      @leads.in_stage(stage).order(updated_at: :desc)
    end
  end
end
