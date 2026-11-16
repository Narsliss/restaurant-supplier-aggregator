class Users::RegistrationsController < Devise::RegistrationsController
  before_action :load_invitation, only: [:new, :create]
  # Runs after load_invitation so a rejected invited chef sees their invite form again.
  before_action :reject_bot_signups, only: [:create]

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

  # Honeypot + minimum fill time (SignupBotGuard). No account is created on a
  # rejection; the form re-renders with a fresh timestamp so a real person
  # caught by mistake gets through on the next submit.
  def reject_bot_signups
    reason = SignupBotGuard.rejection_reason(params)
    return unless reason

    Rails.logger.warn(
      "[SignupBotGuard] blocked reason=#{reason} ip=#{request.remote_ip} " \
      "email_domain=#{sign_up_params[:email].to_s.split('@').last.presence || '-'} " \
      "invited=#{@invitation.present?}"
    )

    build_resource(sign_up_params)
    resource.email = @invitation.email if @invitation
    resource.errors.add(:base, "We couldn't create your account just now. Please check your details and submit again.")
    clean_up_passwords(resource)
    set_minimum_password_length
    render :new, status: :unprocessable_entity
  end

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
