module OrganizationAuthorization
  extend ActiveSupport::Concern

  included do
    helper_method :current_membership, :current_role, :accessible_locations,
                  :owner?, :manager_or_owner?, :chef?
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

  # --- Scoped Queries ---

  # Orders visible to the current user
  def scoped_orders
    org = current_user.current_organization
    return Order.none unless org

    if owner?
      org.orders
    elsif manager_or_owner?
      # Managers see orders for their assigned locations
      org.orders.for_locations(accessible_locations)
    else
      # Chefs see only their own orders
      current_user.orders.for_organization(org)
    end
  end

  # Order lists visible to the current user
  def scoped_order_lists
    org = current_user.current_organization
    return OrderList.none unless org

    if owner?
      org.order_lists
    elsif current_role == 'manager'
      org.order_lists.for_locations(accessible_locations)
    else
      current_user.order_lists.for_organization(org)
    end
  end

  # Supplier credentials visible to the current user
  def scoped_credentials
    org = current_user.current_organization
    return SupplierCredential.none unless org

    if owner?
      org.supplier_credentials
    elsif current_role == 'manager'
      # Managers see creds for users at their assigned locations (read-only)
      user_ids = Membership.joins(:membership_locations)
        .where(organization: org, active: true)
        .where(membership_locations: { location_id: accessible_locations.select(:id) })
        .pluck(:user_id)
      SupplierCredential.where(user_id: user_ids, organization: org)
    else
      # Chefs see only their own
      current_user.supplier_credentials.where(organization: org)
    end
  end

  # --- Guards ---

  def require_owner!
    unless current_user&.super_admin? || owner?
      redirect_to root_path, alert: "Only the organization owner can perform this action."
    end
  end

  def require_owner_or_manager!
    unless current_user&.super_admin? || manager_or_owner?
      redirect_to root_path, alert: "You don't have permission to perform this action."
    end
  end

  def require_organization!
    unless current_user&.current_organization
      redirect_to new_organization_path, alert: "Please create or join an organization first."
    end
  end
end
