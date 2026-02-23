class LocationsController < ApplicationController
  before_action :require_organization!
  before_action :require_owner!, only: [:new, :create, :edit, :update, :destroy]
  before_action :set_location, only: [:show, :edit, :update, :destroy]

  def index
    @locations = accessible_locations.default_first
  end

  def show
    @assigned_members = @location.assigned_members
  end

  def new
    @location = current_user.current_organization.locations.new
  end

  def create
    @location = current_user.current_organization.locations.new(location_params)
    @location.created_by = current_user

    if @location.save
      redirect_to locations_path, notice: "Restaurant created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @location.update(location_params)
      redirect_to locations_path, notice: "Restaurant updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    org = current_user.current_organization
    if org.locations.count > 1
      @location.destroy
      redirect_to locations_path, notice: "Restaurant deleted."
    else
      redirect_to locations_path, alert: "You must have at least one restaurant."
    end
  end

  private

  def set_location
    @location = accessible_locations.find(params[:id])
  end

  def location_params
    params.require(:location).permit(:name, :address, :city, :state, :zip_code, :phone)
  end
end
