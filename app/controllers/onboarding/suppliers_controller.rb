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

      # Build a supplier_id → credential lookup so the picker can
      # distinguish: connected, validating, needs-reconnect, none.
      credentials_by_supplier = if org
                                  current_user.supplier_credentials
                                              .where(organization: org)
                                              .index_by(&:supplier_id)
                                else
                                  {}
                                end

      # Only login-based suppliers belong in the wizard picker. Email
      # suppliers (auth_type=email) don't have a credential form — they
      # are set up by routing the supplier's price-list emails into the
      # inbound parser.
      suppliers = Supplier.active.web_suppliers.by_name.map do |supplier|
        cred = credentials_by_supplier[supplier.id]

        {
          id:                  supplier.id,
          name:                supplier.name,
          auth_type:           supplier.auth_type,
          credential_id:       cred&.id,
          credential_status:   cred&.status, # "active" | "pending" | "failed" | "expired" | "hold" | nil
        }
      end

      render json: { suppliers: suppliers }
    end
  end
end
