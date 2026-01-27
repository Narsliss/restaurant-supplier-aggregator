class LocationsController < ApplicationController
  before_action :set_location, only: [:show, :edit, :update, :destroy]

  def index
    @locations = current_user.locations.default_first
  end

  def show
  end

  def new
    @location = current_user.locations.new
  end

  def create
    @location = current_user.locations.new(location_params)

    if @location.save
      redirect_to locations_path, notice: "Location created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @location.update(location_params)
      redirect_to locations_path, notice: "Location updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if current_user.locations.count > 1
      @location.destroy
      redirect_to locations_path, notice: "Location deleted."
    else
      redirect_to locations_path, alert: "You must have at least one location."
    end
  end

  private

  def set_location
    @location = current_user.locations.find(params[:id])
  end

  def location_params
    params.require(:location).permit(:name, :address, :city, :state, :zip_code, :phone, :is_default)
  end
end
