class Crm::LeadsController < Crm::BaseController
  before_action :set_lead, only: [:show, :edit, :update, :destroy, :move_stage, :update_next_action, :convert, :detail_panel]

  def index
    @leads = Crm::Lead.includes(:salesperson, :tags).order(updated_at: :desc)
    @leads = @leads.in_stage(params[:stage]) if params[:stage].present?
    @leads = @leads.where("restaurant_name ILIKE :q OR contact_name ILIKE :q", q: "%#{params[:q]}%") if params[:q].present?
    @leads = @leads.for_salesperson(User.find(params[:salesperson_id])) if params[:salesperson_id].present?

    @salespeople = User.where(role: "salesperson").order(:first_name) if current_user.super_admin?

    @view = params[:view] || "list"

    if @view == "kanban"
      @leads_by_stage = Crm::Lead::PIPELINE_STAGES.index_with do |stage|
        @leads.in_stage(stage).order(updated_at: :desc)
      end
    else
      @page = [params[:page].to_i, 1].max
      @per_page = 25
      @total_count = @leads.count
      @leads = @leads.offset((@page - 1) * @per_page).limit(@per_page)
    end
  end

  def show
    @activities = @lead.activities.recent.includes(:user)
    @tasks = @lead.tasks.includes(:assigned_to).order(:due_date)
    @pending_tasks = @tasks.select { |t| !t.completed? }
    @completed_tasks = @tasks.select { |t| t.completed? }
  end

  def new
    @lead = Crm::Lead.new(salesperson: current_user)
  end

  def create
    @lead = Crm::Lead.new(lead_params)
    @lead.salesperson = current_user

    if @lead.save
      redirect_to crm_lead_path(@lead), notice: "Lead created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @lead.update(lead_params)
      redirect_to crm_lead_path(@lead), notice: "Lead updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @lead.destroy
    redirect_to crm_leads_path, notice: "Lead deleted."
  end

  def move_stage
    new_stage = params[:pipeline_stage]
    if Crm::Lead::PIPELINE_STAGES.include?(new_stage)
      @lead.update!(
        pipeline_stage: new_stage,
        closed_at: %w[closed_won closed_lost].include?(new_stage) ? Time.current : nil
      )
      respond_to do |format|
        format.html { redirect_to crm_leads_path(view: "kanban") }
        format.json { render json: { status: "ok", stage: new_stage } }
      end
    else
      respond_to do |format|
        format.html { redirect_to crm_leads_path(view: "kanban"), alert: "Invalid stage." }
        format.json { render json: { error: "Invalid stage" }, status: :unprocessable_entity }
      end
    end
  end

  def detail_panel
    @activities = @lead.activities.recent.includes(:user).limit(5)
    @tasks = @lead.tasks.pending.order(:due_date).limit(5)
    render partial: "crm/leads/detail_panel", layout: false
  end

  def update_next_action
    old_action = @lead.next_action
    new_action = params[:next_action].to_s.strip
    completed = params[:completed] == "true"

    if completed && old_action.present?
      # Log the completed action as an activity
      @lead.activities.create!(
        user: current_user,
        activity_type: "note",
        subject: "Completed next action",
        body: old_action,
        occurred_at: Time.current
      )
      @lead.update!(next_action: new_action.presence)
    else
      @lead.update!(next_action: new_action.presence)
    end

    respond_to do |format|
      format.html { redirect_to crm_lead_path(@lead), notice: "Next action updated." }
      format.json { render json: { status: "ok", next_action: @lead.next_action } }
    end
  end

  def convert
    if @lead.won? && @lead.organization.blank?
      org = @lead.convert_to_organization!
      redirect_to crm_lead_path(@lead), notice: "Converted to organization: #{org.name}"
    else
      redirect_to crm_lead_path(@lead), alert: "Lead must be Closed Won and not yet converted."
    end
  end

  private

  def set_lead
    @lead = Crm::Lead.find(params[:id])
  end

  def lead_params
    params.require(:crm_lead).permit(
      :restaurant_name, :contact_name, :contact_role,
      :phone, :email, :city, :state,
      :estimated_volume, :pain_point, :current_suppliers,
      :deal_value_dollars, :pipeline_stage, :next_action, :lost_reason
    )
  end
end
