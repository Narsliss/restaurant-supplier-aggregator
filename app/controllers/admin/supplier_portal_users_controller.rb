class Admin::SupplierPortalUsersController < Admin::BaseController
  def index
    @supplier_users = SupplierUser.includes(:supplier).order(:email)
    @pending_invitations = SupplierPortalInvitation.pending.includes(:supplier).order(created_at: :desc)
  end

  def new
    @suppliers = Supplier.active.by_name
  end

  def create
    supplier = Supplier.find(params[:supplier_id])

    invitation = SupplierPortalInvitation.new(
      supplier: supplier,
      email: params[:email],
      role: params[:role] || "admin",
      invited_by: current_user
    )

    if invitation.save
      redirect_to admin_supplier_portal_users_path,
        notice: "Invitation sent to #{params[:email]} for #{supplier.name}."
    else
      @suppliers = Supplier.active.by_name
      @errors = invitation.errors
      render :new, status: :unprocessable_entity
    end
  end
end
