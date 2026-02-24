module Organizations
  class InvitationsController < ApplicationController
    before_action :set_organization, except: [:accept]
    before_action :require_owner!, except: [:accept]
    before_action :set_invitation, only: %i[edit update]
    skip_before_action :authenticate_user!, only: [:accept]

    def create
      @invitation = @organization.organization_invitations.new(invitation_params)
      @invitation.invited_by = current_user

      # Check if user is already a member
      if User.exists?(email: @invitation.email) &&
         @organization.member?(User.find_by(email: @invitation.email))
        redirect_to organization_path(error: "already_member")
        return
      end

      if @invitation.save
        # TODO: Send invitation email
        redirect_to organization_path(invited: @invitation.email)
      else
        redirect_to organization_path(error: @invitation.errors.full_messages.first)
      end
    end

    def edit
      @locations = @organization.locations
    end

    def update
      if @invitation.update(invitation_params)
        redirect_to organization_path(updated: @invitation.email)
      else
        @locations = @organization.locations
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @invitation = @organization.organization_invitations.find(params[:id])
      @invitation.destroy
      redirect_to organization_path(canceled: @invitation.email)
    end

    def resend
      @invitation = @organization.organization_invitations.find(params[:id])
      if @invitation.resend!
        redirect_to organization_path(resent: @invitation.email)
      else
        redirect_to organization_path(error: "Unable to resend invitation.")
      end
    end

    # Public endpoint to accept invitation
    def accept
      @invitation = OrganizationInvitation.find_by(token: params[:token])

      if @invitation.nil?
        redirect_to root_path
        return
      end

      if @invitation.expired?
        redirect_to root_path
        return
      end

      if @invitation.accepted?
        redirect_to root_path
        return
      end

      # If user is logged in, accept the invitation
      if user_signed_in?
        if current_user.email.downcase != @invitation.email.downcase
          redirect_to root_path
          return
        end

        @invitation.accept!(current_user)
        redirect_to root_path
      else
        # Check if user exists
        existing_user = User.find_by(email: @invitation.email)
        if existing_user
          # Redirect to login with return URL
          store_location_for(:user, accept_invitation_url(token: @invitation.token))
          redirect_to new_user_session_path
        else
          # Redirect to registration with invitation context
          session[:invitation_token] = @invitation.token
          redirect_to new_user_registration_path
        end
      end
    end

    private

    def set_organization
      @organization = current_user.current_organization
      redirect_to root_path unless @organization
    end

    def set_invitation
      @invitation = @organization.organization_invitations.pending.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to organization_path
    end

    def invitation_params
      params.require(:organization_invitation).permit(:email, :role, :location_id, location_ids: [])
    end

  end
end
