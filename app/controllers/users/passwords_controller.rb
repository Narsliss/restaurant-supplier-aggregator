class Users::PasswordsController < Devise::PasswordsController
  # POST /users/password
  # Override to show inline confirmation instead of flash + redirect
  def create
    self.resource = resource_class.send_reset_password_instructions(resource_params)
    yield resource if block_given?

    if successfully_sent?(resource)
      @reset_email_sent = true
      # Re-render the form with success message instead of redirecting
      self.resource = resource_class.new
      render :new
    else
      respond_with(resource)
    end
  end
end
