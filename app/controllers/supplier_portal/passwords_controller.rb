class SupplierPortal::PasswordsController < Devise::PasswordsController
  layout "supplier_portal_auth"

  # Override to redirect with ?sent=true param (same pattern as Users::PasswordsController)
  def create
    self.resource = resource_class.send_reset_password_instructions(resource_params)
    redirect_to new_supplier_user_password_path(sent: true)
  end
end
