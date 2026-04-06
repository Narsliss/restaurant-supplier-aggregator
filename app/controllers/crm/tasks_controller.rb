class Crm::TasksController < Crm::BaseController
  before_action :set_lead, except: [:index]
  before_action :set_task, only: [:edit, :update, :destroy, :complete]

  # Standalone: /crm/tasks — all my tasks
  def index
    @tasks = Crm::Task.includes(:lead, :assigned_to)
                       .for_user(current_user)
                       .order(:due_date)
    @overdue = @tasks.overdue
    @upcoming = @tasks.upcoming
    @completed = @tasks.where.not(completed_at: nil).order(completed_at: :desc).limit(20)
  end

  def create
    @task = @lead.tasks.build(task_params)
    @task.assigned_to = current_user

    if @task.save
      redirect_to crm_lead_path(@lead), notice: "Task created."
    else
      redirect_to crm_lead_path(@lead), alert: "Could not create task."
    end
  end

  def edit
  end

  def update
    if @task.update(task_params)
      redirect_to crm_lead_path(@lead), notice: "Task updated."
    else
      redirect_to crm_lead_path(@lead), alert: "Could not update task."
    end
  end

  def destroy
    @task.destroy
    redirect_to crm_lead_path(@lead), notice: "Task removed."
  end

  def complete
    @task.complete!
    respond_to do |format|
      format.html { redirect_to crm_lead_path(@lead), notice: "Task completed." }
      format.json { render json: { status: "ok" } }
    end
  end

  private

  def set_lead
    @lead = Crm::Lead.find(params[:lead_id])
  end

  def set_task
    @task = @lead.tasks.find(params[:id])
  end

  def task_params
    params.require(:crm_task).permit(:title, :description, :due_date, :priority)
  end
end
