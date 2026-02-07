module Organizations
  class InvitationsController < ApplicationController
    before_action :set_organization, except: [:accept]
    before_action :require_admin!, except: [:accept]
    skip_before_action :authenticate_user!, only: [:accept]

    def create
      @invitation = @organization.organization_invitations.new(invitation_params)
      @invitation.invited_by = current_user

      # Check if user is already a member
      if User.exists?(email: @invitation.email) &&
         @organization.member?(User.find_by(email: @invitation.email))
        redirect_to organization_path, alert: "This person is already a member of your organization."
        return
      end

      if @invitation.save
        # TODO: Send invitation email
        redirect_to organization_path, notice: "Invitation sent to #{@invitation.email}."
      else
        redirect_to organization_path, alert: @invitation.errors.full_messages.join(", ")
      end
    end

    def destroy
      @invitation = @organization.organization_invitations.find(params[:id])
      @invitation.destroy
      redirect_to organization_path, notice: "Invitation canceled."
    end

    def resend
      @invitation = @organization.organization_invitations.find(params[:id])
      if @invitation.resend!
        redirect_to organization_path, notice: "Invitation resent to #{@invitation.email}."
      else
        redirect_to organization_path, alert: "Unable to resend invitation."
      end
    end

    # Public endpoint to accept invitation
    def accept
      @invitation = OrganizationInvitation.find_by(token: params[:token])

      if @invitation.nil?
        redirect_to root_path, alert: "Invalid invitation link."
        return
      end

      if @invitation.expired?
        redirect_to root_path, alert: "This invitation has expired. Please request a new one."
        return
      end

      if @invitation.accepted?
        redirect_to root_path, alert: "This invitation has already been accepted."
        return
      end

      # If user is logged in, accept the invitation
      if user_signed_in?
        if current_user.email.downcase != @invitation.email.downcase
          redirect_to root_path, alert: "This invitation was sent to a different email address."
          return
        end

        @invitation.accept!(current_user)
        redirect_to root_path, notice: "You've joined #{@invitation.organization.name}!"
      else
        # Check if user exists
        existing_user = User.find_by(email: @invitation.email)
        if existing_user
          # Redirect to login with return URL
          store_location_for(:user, accept_invitation_url(token: @invitation.token))
          redirect_to new_user_session_path, notice: "Please sign in to accept your invitation."
        else
          # Redirect to registration with invitation context
          session[:invitation_token] = @invitation.token
          redirect_to new_user_registration_path, notice: "Create an account to join #{@invitation.organization.name}."
        end
      end
    end

    private

    def set_organization
      @organization = current_user.current_organization
      redirect_to root_path, alert: "No organization selected." unless @organization
    end

    def require_admin!
      unless current_user.admin_of?(@organization)
        redirect_to organization_path, alert: "You don't have permission to manage invitations."
      end
    end

    def invitation_params
      params.require(:organization_invitation).permit(:email, :role)
    end
  end
end
