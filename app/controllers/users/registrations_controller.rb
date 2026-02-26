class Users::RegistrationsController < Devise::RegistrationsController
  before_action :load_invitation, only: [:new, :create]

  # GET /users/sign_up
  def new
    build_resource({})

    # Pre-fill email from invitation so the field is read-only
    resource.email = @invitation.email if @invitation

    yield resource if block_given?
    respond_with resource
  end

  protected

  # After registration, auto-accept any pending invitation
  def after_sign_up_path_for(resource)
    if session[:invitation_token].present?
      invitation = OrganizationInvitation.find_by(token: session[:invitation_token])
      if invitation&.pending?
        invitation.accept!(resource)
        # The chef lands on a welcoming onboarding wizard — suppress the
        # generic Devise "signed up successfully" flash so it doesn't wedge
        # between the nav and the hero.
        flash.discard(:notice)
      end
      session.delete(:invitation_token)
    end
    root_path
  end

  def after_update_path_for(resource)
    root_path
  end

  private

  def load_invitation
    return unless session[:invitation_token].present?

    @invitation = OrganizationInvitation.find_by(token: session[:invitation_token])

    # Clear stale/invalid tokens
    if @invitation.nil? || @invitation.expired? || @invitation.accepted?
      session.delete(:invitation_token)
      @invitation = nil
    end
  end
end
