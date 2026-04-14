class OrganizationsController < ApplicationController
  before_action :set_organization, only: [:show, :edit, :update, :update_requirement, :update_delivery_schedule]
  before_action :require_owner!, only: [:edit, :update, :update_requirement, :update_delivery_schedule]

  def show
    @members = @organization.memberships.active.includes(:user, :locations).order(:role, :created_at)
    @pending_invitations = @organization.organization_invitations.pending.includes(:location)
    @locations = @organization.locations
    @seat_count = @organization.seat_count
    @seat_limit = @organization.seat_limit

    # Supplier requirements for owner view
    if owner?
      connected_supplier_ids = SupplierCredential.where(organization: @organization).select(:supplier_id).distinct
      @suppliers = Supplier.active.where(id: connected_supplier_ids).order(:name)
      supplier_ids = @suppliers.pluck(:id)
      location_ids = @locations.pluck(:id)

      # Case minimums
      @case_minimums = SupplierRequirement.where(
        requirement_type: 'case_minimum', active: true,
        supplier_id: supplier_ids, location_id: location_ids
      ).index_by { |r| [r.supplier_id, r.location_id] }

      @global_case_minimums = SupplierRequirement.where(
        requirement_type: 'case_minimum', active: true,
        supplier_id: supplier_ids, location_id: nil
      ).index_by(&:supplier_id)

      # Order (dollar) minimums
      @order_minimums = SupplierRequirement.where(
        requirement_type: 'order_minimum', active: true,
        supplier_id: supplier_ids, location_id: location_ids
      ).index_by { |r| [r.supplier_id, r.location_id] }

      @global_order_minimums = SupplierRequirement.where(
        requirement_type: 'order_minimum', active: true,
        supplier_id: supplier_ids, location_id: nil
      ).index_by(&:supplier_id)

      # Delivery schedules
      @delivery_schedules = SupplierDeliverySchedule.where(
        supplier_id: supplier_ids, active: true, location_id: nil
      ).order(:day_of_week).group_by(&:supplier_id)
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

  def update_requirement
    supplier = Supplier.find(params[:supplier_id])
    req_type = params[:requirement_type]

    unless req_type.in?(%w[case_minimum order_minimum])
      return render json: { error: 'Invalid requirement type' }, status: :unprocessable_entity
    end

    is_global = params[:location_id].blank?
    location = is_global ? nil : @organization.locations.find(params[:location_id])
    value = params[:value].to_f

    if value > 0
      req = SupplierRequirement.find_or_initialize_by(
        supplier: supplier, location: location, requirement_type: req_type
      )
      error_message = if req_type == 'case_minimum'
                        "#{supplier.name} requires a minimum of {{minimum}} cases per order. You have {{current_count}} cases."
                      else
                        "#{supplier.name} requires a minimum order of ${{minimum}}. Your current total is ${{current_total}}."
                      end
      req.assign_attributes(
        numeric_value: value, is_blocking: req_type == 'order_minimum',
        active: true, error_message: error_message
      )
      req.save!

      # Global default supercedes all location overrides
      if is_global
        SupplierRequirement.where(
          supplier: supplier, requirement_type: req_type
        ).where.not(location_id: nil).destroy_all
      end

      render json: { saved: true, global: is_global }
    else
      SupplierRequirement.where(
        supplier: supplier, location: location, requirement_type: req_type
      ).destroy_all

      render json: { saved: true, removed: true, global: is_global }
    end
  end

  def update_delivery_schedule
    supplier = Supplier.find(params[:supplier_id])
    day_of_week = params[:day_of_week].to_i
    enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])

    schedule = SupplierDeliverySchedule.find_or_initialize_by(
      supplier: supplier, location: nil, day_of_week: day_of_week
    )

    if enabled
      cutoff_day = params[:cutoff_day].present? ? params[:cutoff_day].to_i : ((day_of_week - 1) % 7)
      cutoff_time = params[:cutoff_time].present? ? Time.zone.parse(params[:cutoff_time]) : Time.zone.parse("17:00")

      schedule.assign_attributes(
        cutoff_day: cutoff_day,
        cutoff_time: cutoff_time,
        active: true
      )
      schedule.save!

      render json: {
        saved: true,
        schedule: {
          id: schedule.id,
          day_of_week: schedule.day_of_week,
          day_name: schedule.day_name,
          cutoff_day: schedule.cutoff_day,
          cutoff_day_name: schedule.cutoff_day_name,
          cutoff_time: schedule.cutoff_time.strftime("%H:%M"),
          formatted: schedule.formatted_schedule
        }
      }
    else
      schedule.destroy if schedule.persisted?
      render json: { saved: true, removed: true }
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
