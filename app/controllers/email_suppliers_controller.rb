class EmailSuppliersController < ApplicationController
  before_action :require_operator!
  before_action :require_location_context!
  before_action :set_supplier, only: [:edit, :update, :destroy]

  def new
    @supplier = Supplier.new(auth_type: 'email')
  end

  def create
    @supplier = Supplier.new(supplier_params)
    @supplier.auth_type = 'email'
    @supplier.organization = current_user.current_organization
    @supplier.created_by_id = current_user.id
    @supplier.code = generate_code(@supplier.name)
    @supplier.active = true
    @supplier.password_required = false

    if @supplier.save
      Rails.logger.info "[EmailSuppliers] Created email supplier '#{@supplier.name}' (id: #{@supplier.id}) for org #{@supplier.organization_id} by user #{current_user.id}"
      redirect_to supplier_credentials_path,
                  notice: "#{@supplier.name} added. Upload a PDF price list to get started."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @supplier.update(supplier_params)
      redirect_to supplier_credentials_path,
                  notice: "#{@supplier.name} updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @supplier.name
    @supplier.destroy!
    redirect_to supplier_credentials_path,
                notice: "#{name} removed."
  end

  private

  def set_supplier
    @supplier = Supplier.email_suppliers
                        .where(organization: current_user.current_organization)
                        .find(params[:id])
  end

  def supplier_params
    params.require(:supplier).permit(:name, :contact_email, :ordering_instructions)
  end

  def generate_code(name)
    base = "email-#{name.to_s.parameterize}-#{current_user.current_organization_id}"
    # Ensure uniqueness
    if Supplier.exists?(code: base)
      "#{base}-#{SecureRandom.hex(3)}"
    else
      base
    end
  end
end
