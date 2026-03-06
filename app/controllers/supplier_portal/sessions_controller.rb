class SupplierPortal::SessionsController < Devise::SessionsController
  layout "supplier_portal_auth"

  protected

  def after_sign_in_path_for(_resource)
    supplier_portal_root_path
  end

  def after_sign_out_path_for(_resource)
    new_supplier_user_session_path
  end
end
