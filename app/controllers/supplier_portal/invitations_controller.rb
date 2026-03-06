# Handles supplier portal invitation acceptance.
# These routes are PUBLIC (no auth required) — the invitation token is the credential.
class SupplierPortal::InvitationsController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  skip_before_action :ensure_onboarding_complete, raise: false
  skip_before_action :require_subscription, raise: false

  layout "supplier_portal_auth"

  before_action :load_invitation

  # GET /supplier/invitations/:token/accept
  def show
    if @invitation.accepted?
      redirect_to new_supplier_user_session_path, notice: "This invitation has already been accepted. Please sign in."
    elsif @invitation.expired?
      redirect_to new_supplier_user_session_path, alert: "This invitation has expired. Please contact your administrator."
    end
  end

  # POST /supplier/invitations/:token/accept
  def accept
    if @invitation.accepted?
      redirect_to new_supplier_user_session_path, notice: "This invitation has already been accepted."
      return
    end

    if @invitation.expired?
      redirect_to new_supplier_user_session_path, alert: "This invitation has expired."
      return
    end

    supplier_user = SupplierUser.new(
      supplier: @invitation.supplier,
      email: @invitation.email,
      role: @invitation.role,
      first_name: params[:first_name],
      last_name: params[:last_name],
      password: params[:password],
      password_confirmation: params[:password_confirmation],
      invitation_token: @invitation.token
    )

    if supplier_user.save
      @invitation.accept!(supplier_user)
      sign_in(:supplier_user, supplier_user)
      redirect_to supplier_portal_root_path, notice: "Welcome to the Supplier Portal!"
    else
      @errors = supplier_user.errors
      render :show, status: :unprocessable_entity
    end
  end

  private

  def load_invitation
    @invitation = SupplierPortalInvitation.find_by!(token: params[:token])
  rescue ActiveRecord::RecordNotFound
    redirect_to new_supplier_user_session_path, alert: "Invalid invitation link."
  end
end
