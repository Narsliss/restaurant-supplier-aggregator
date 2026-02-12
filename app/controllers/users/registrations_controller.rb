class Users::RegistrationsController < Devise::RegistrationsController
  protected

  # Redirect to dashboard after registration
  # TODO: Re-enable subscription redirect when payments are active
  # def after_sign_up_path_for(resource)
  #   new_subscription_path
  # end
  def after_sign_up_path_for(resource)
    root_path
  end

  def after_update_path_for(resource)
    root_path
  end
end
