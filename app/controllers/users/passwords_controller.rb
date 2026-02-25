class Users::PasswordsController < Devise::PasswordsController
  # POST /users/password
  # Override to show inline confirmation instead of flash + redirect
  def create
    self.resource = resource_class.send_reset_password_instructions(resource_params)
    yield resource if block_given?

    if successfully_sent?(resource)
      # Redirect with query param so the view shows the "check your email" state
      # This works with Turbo (which expects a redirect after POST)
      redirect_to new_user_password_path(sent: true)
    else
      respond_with(resource)
    end
  end
end
