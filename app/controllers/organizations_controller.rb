class OrganizationsController < ApplicationController
  before_action :set_organization, only: [:show, :edit, :update]
  before_action :require_owner!, only: [:edit, :update]

  def show
    @members = @organization.memberships.active.includes(:user, :locations).order(:role, :created_at)
    @pending_invitations = @organization.organization_invitations.pending.includes(:location)
    @locations = @organization.locations
    @seat_count = @organization.seat_count
    @seat_limit = @organization.seat_limit
  end

  def new
    @organization = Organization.new
  end

  def create
    @organization = current_user.create_organization!(
      name: organization_params[:name],
      phone: organization_params[:phone],
      address: organization_params[:address],
      city: organization_params[:city],
      state: organization_params[:state],
      zip_code: organization_params[:zip_code]
    )

    redirect_to root_path
  rescue ActiveRecord::RecordInvalid => e
    @organization = Organization.new(organization_params)
    @organization.errors.merge!(e.record.errors)
    render :new, status: :unprocessable_entity
  end

  def edit
  end

  def update
    if @organization.update(organization_params)
      redirect_to organization_path(@organization)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def switch
    org = current_user.organizations.find(params[:id])
    current_user.switch_organization!(org)
    redirect_to root_path
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path
  end

  private

  def set_organization
    @organization = current_user.current_organization
    redirect_to new_organization_path unless @organization
  end

  def organization_params
    params.require(:organization).permit(:name, :phone, :address, :city, :state, :zip_code, :timezone)
  end
end
