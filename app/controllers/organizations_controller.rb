class OrganizationsController < ApplicationController
  before_action :set_organization, only: [:show, :edit, :update, :update_case_minimum]
  before_action :require_owner!, only: [:edit, :update, :update_case_minimum]

  def show
    @members = @organization.memberships.active.includes(:user, :locations).order(:role, :created_at)
    @pending_invitations = @organization.organization_invitations.pending.includes(:location)
    @locations = @organization.locations
    @seat_count = @organization.seat_count
    @seat_limit = @organization.seat_limit

    # Case minimums for owner view
    if owner?
      @suppliers = Supplier.active.order(:name)
      @case_minimums = SupplierRequirement.where(
        requirement_type: 'case_minimum',
        active: true
      ).where(supplier_id: @suppliers.pluck(:id))
       .where(location_id: @locations.pluck(:id))
       .index_by { |r| [r.supplier_id, r.location_id] }

      @global_case_minimums = SupplierRequirement.where(
        requirement_type: 'case_minimum',
        active: true,
        location_id: nil
      ).where(supplier_id: @suppliers.pluck(:id))
       .index_by(&:supplier_id)
    end
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

  def update_case_minimum
    supplier = Supplier.find(params[:supplier_id])
    location = @organization.locations.find(params[:location_id])
    value = params[:case_minimum].to_i

    if value > 0
      req = SupplierRequirement.find_or_initialize_by(
        supplier: supplier,
        location: location,
        requirement_type: 'case_minimum'
      )
      req.assign_attributes(
        numeric_value: value,
        is_blocking: false,
        active: true,
        error_message: "#{supplier.name} requires a minimum of {{minimum}} cases per order. You have {{current_count}} cases. An additional charge may apply."
      )
      req.save!
      redirect_to organization_path, notice: "Case minimum for #{supplier.name} at #{location.name} set to #{value}."
    else
      SupplierRequirement.where(
        supplier: supplier, location: location, requirement_type: 'case_minimum'
      ).destroy_all
      redirect_to organization_path, notice: "Case minimum for #{supplier.name} at #{location.name} removed."
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
