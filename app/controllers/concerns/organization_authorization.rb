module OrganizationAuthorization
  extend ActiveSupport::Concern

  included do
    helper_method :current_membership, :current_role, :accessible_locations,
                  :owner?, :manager_or_owner?, :chef?, :operator?
  end

  private

  # --- Helpers ---

  def current_membership
    @current_membership ||= current_user&.membership_for(current_user&.current_organization)
  end

  def current_role
    current_membership&.role
  end

  def accessible_locations
    @accessible_locations ||= begin
      return Location.none unless current_user&.current_organization
      current_user.accessible_locations
    end
  end

  def owner?
    current_role == 'owner'
  end

  def manager_or_owner?
    %w[owner manager].include?(current_role)
  end

  def chef?
    current_role == 'chef'
  end

  # Operators can create/edit things (owners + chefs). Managers cannot.
  def operator?
    %w[owner chef].include?(current_role)
  end

  # --- Scoped Queries (location-context aware) ---

  # Orders visible to the current user, filtered by current_location when set
  def scoped_orders
    org = current_user.current_organization
    return Order.none unless org

    base = if owner?
      if current_location
        org.orders.where(location: current_location)
      else
        org.orders # "All Locations" aggregate
      end
    elsif current_role == 'manager'
      if current_location
        org.orders.where(location: current_location)
      else
        org.orders.where(location_id: accessible_locations.select(:id))
      end
    else
      # Chef: orders at their assigned location (chefs are pinned to a single location)
      # This lets chefs review/submit orders created by any user at their location
      if current_location
        org.orders.where(location: current_location)
      else
        current_user.orders.where(organization: org)
      end
    end

    base
  end

  # Order lists are shared per-location (not per-user)
  def scoped_order_lists
    org = current_user.current_organization
    return OrderList.none unless org

    if current_location
      # All roles see the location's shared lists
      OrderList.where(location: current_location, organization: org)
    elsif owner?
      # "All Locations" — show all org lists
      org.order_lists
    else
      # Manager without specific location — show lists for assigned locations
      org.order_lists.where(location_id: accessible_locations.select(:id))
    end
  end

  # Supplier credentials scoped to current location
  def scoped_credentials
    org = current_user.current_organization
    return SupplierCredential.none unless org

    if owner?
      # Owners see only their own credentials, filtered by location when one is selected
      base = current_user.supplier_credentials.where(organization: org)
      current_location ? base.where(location: current_location) : base
    elsif current_role == 'manager'
      # Managers see credentials at their current location (read-only enforced in controller)
      if current_location
        org.supplier_credentials.where(location: current_location)
      else
        org.supplier_credentials.where(location_id: accessible_locations.select(:id))
      end
    else
      # Chef: own credentials only
      current_user.supplier_credentials.where(organization: org)
    end
  end

  # Sort suppliers by the current user's display_position preference.
  # Falls back to supplier name for any without a position set.
  def sort_suppliers_for_user(suppliers)
    positions = scoped_credentials.where(supplier_id: suppliers.map(&:id))
                                  .pluck(:supplier_id, :display_position)
                                  .to_h
    suppliers.sort_by { |s| [positions[s.id] || 999, s.name] }
  end

  # Supplier lists scoped to current location (shared per restaurant)
  def scoped_supplier_lists
    org = current_user.current_organization
    return SupplierList.none unless org

    base = if current_location
      SupplierList.where(location: current_location, organization: org)
    elsif owner?
      org.supplier_lists
    else
      org.supplier_lists.where(location_id: accessible_locations.select(:id))
    end

    # Chefs only see lists from suppliers they have credentials for.
    # Uses supplier_id (not supplier_credential_id) so if the owner imported
    # lists and the chef has the same supplier connected, the chef sees them.
    if chef?
      chef_supplier_ids = current_user.supplier_credentials
                            .where(organization: org)
                            .select(:supplier_id)
      base = base.where(supplier_id: chef_supplier_ids)
    end

    base
  end

  # --- Guards ---

  def require_owner!
    unless current_user&.super_admin? || owner?
      redirect_to root_path
    end
  end

  def require_owner_or_manager!
    unless current_user&.super_admin? || manager_or_owner?
      redirect_to root_path
    end
  end

  # Operators = owners + chefs (can create/edit/delete operational data)
  # Managers are read-only and blocked by this guard
  def require_operator!
    unless current_user&.super_admin? || operator?
      redirect_to root_path
    end
  end

  # Requires a specific location to be selected (blocks "All Locations" mode)
  def require_location_context!
    return if current_user&.super_admin?

    unless current_location
      redirect_to root_path, alert: "Please select a specific restaurant from the dropdown above to access this page."
    end
  end

  def require_organization!
    return if current_user&.super_admin?

    unless current_user&.current_organization
      redirect_to new_organization_path
    end
  end
end
