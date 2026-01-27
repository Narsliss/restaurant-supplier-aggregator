class SupplierCredentialsController < ApplicationController
  before_action :set_credential, only: [:show, :edit, :update, :destroy, :validate, :refresh_session]
  before_action :set_suppliers, only: [:new, :create, :edit, :update]

  def index
    @credentials = current_user.supplier_credentials
      .includes(:supplier, :location)
      .order("suppliers.name")
  end

  def show
  end

  def new
    @credential = current_user.supplier_credentials.new
  end

  def create
    @credential = current_user.supplier_credentials.new(credential_params)

    if @credential.save
      redirect_to supplier_credentials_path, notice: "Credentials saved. Validating..."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @credential.update(credential_params)
      # Re-validate credentials after update
      ValidateCredentialsJob.perform_later(@credential.id)
      redirect_to supplier_credentials_path, notice: "Credentials updated. Re-validating..."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @credential.destroy
    redirect_to supplier_credentials_path, notice: "Credentials removed."
  end

  def validate
    ValidateCredentialsJob.perform_later(@credential.id)
    
    respond_to do |format|
      format.html { redirect_to supplier_credentials_path, notice: "Validation started..." }
      format.json { render json: { status: "validating" } }
    end
  end

  def refresh_session
    RefreshSessionJob.perform_later(@credential.id)
    
    respond_to do |format|
      format.html { redirect_to supplier_credentials_path, notice: "Session refresh started..." }
      format.json { render json: { status: "refreshing" } }
    end
  end

  private

  def set_credential
    @credential = current_user.supplier_credentials.find(params[:id])
  end

  def set_suppliers
    # Only show suppliers that user doesn't have credentials for (at this location)
    existing_supplier_ids = current_user.supplier_credentials
      .where(location: current_location)
      .pluck(:supplier_id)
    
    @available_suppliers = Supplier.active.where.not(id: existing_supplier_ids).order(:name)
    @all_suppliers = Supplier.active.order(:name)
  end

  def credential_params
    params.require(:supplier_credential).permit(:supplier_id, :location_id, :username, :password)
  end
end
