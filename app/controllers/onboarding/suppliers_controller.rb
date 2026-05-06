module Onboarding
  # JSON endpoint feeding the wizard's iterative supplier picker.
  # Returns the list of available suppliers + whether the current user
  # has an active credential for each, so the wizard can render
  # "Connect" buttons or "✓ Connected" badges accordingly.
  #
  # READ-ONLY. Never writes to the DB.
  class SuppliersController < ApplicationController
    skip_before_action :ensure_onboarding_complete, raise: false
    skip_before_action :require_subscription,       raise: false

    def index
      org = current_user.current_organization

      connected_supplier_ids = if org
                                 current_user.supplier_credentials
                                             .where(organization: org, status: %w[active pending])
                                             .pluck(:supplier_id)
                               else
                                 []
                               end

      suppliers = Supplier.active.by_name.map do |supplier|
        {
          id:        supplier.id,
          name:      supplier.name,
          auth_type: supplier.auth_type,
          connected: connected_supplier_ids.include?(supplier.id),
        }
      end

      render json: { suppliers: suppliers }
    end
  end
end
