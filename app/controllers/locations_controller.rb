class LocationsController < ApplicationController
  before_action :require_organization!, except: [:switch]
  before_action :require_owner!, only: [:new, :create, :edit, :update, :destroy]
  before_action :set_location, only: [:show, :edit, :update, :destroy]

  # POST /locations/switch — changes the current location context via session
  def switch
    location_id = params[:location_id]

    if location_id.blank? || location_id == "all"
      # "All Locations" mode (owner only)
      session[:current_location_id] = "all"
      head :ok
    else
      location = accessible_locations.find_by(id: location_id)
      if location
        session[:current_location_id] = location.id
        head :ok
      else
        head :forbidden
      end
    end
  end

  def index
    @locations = accessible_locations.default_first
  end

  def show
    @assigned_members = @location.assigned_members
  end

  def new
    @location = Location.new(organization: current_user.current_organization)
  end

  def create
    @location = current_user.current_organization.locations.new(location_params)
    @location.created_by = current_user

    if @location.save
      if onboarding_incomplete?
        # During onboarding, offer to add another restaurant
        redirect_to new_location_path(added: @location.name)
      else
        redirect_to locations_path
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @location.update(location_params)
      redirect_to onboarding_incomplete? ? new_location_path(added: @location.name) : locations_path
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    org = current_user.current_organization
    if org.locations.count > 1
      @location.destroy
      redirect_to onboarding_incomplete? ? new_location_path(added: "Restaurant") : locations_path
    else
      redirect_to (onboarding_incomplete? ? new_location_path : locations_path)
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
