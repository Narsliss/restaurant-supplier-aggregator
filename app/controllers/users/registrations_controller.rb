class Users::RegistrationsController < Devise::RegistrationsController
  protected

  # Redirect to subscription page after registration
  def after_sign_up_path_for(resource)
    new_subscription_path
  end

  # Also redirect after update if they still need to subscribe
  def after_update_path_for(resource)
    if resource.subscribed?
      root_path
    else
      new_subscription_path
    end
  end
end
