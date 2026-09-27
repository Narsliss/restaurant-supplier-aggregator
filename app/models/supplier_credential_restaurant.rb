# Ties one supplier-side restaurant on a multi-restaurant login (a US Foods
# customer, a Chef's Warehouse organization, a What Chefs Want company) to one
# EnPlace location. Before any sync or order for that location, the connection
# is switched to this restaurant and the switch is confirmed — see
# Suppliers::RestaurantSwitcher.
#
# Blast radius: only owners and managers can have these. A connection with no
# restaurant matches behaves exactly as it always has.
class SupplierCredentialRestaurant < ApplicationRecord
  belongs_to :supplier_credential
  belongs_to :location

  validates :supplier_account_id, presence: true
  validates :location_id, uniqueness: { scope: :supplier_credential_id }
  validates :supplier_account_id, uniqueness: { scope: :supplier_credential_id }
  validate :location_in_credentials_organization
  validate :credential_belongs_to_owner_or_manager
  validate :home_restaurant_linked_first, on: :create

  private

  # A login with links always switches before working, so its own (home)
  # restaurant must be linked before any other — otherwise work for the home
  # restaurant would run wherever the login was last left.
  def home_restaurant_linked_first
    cred = supplier_credential
    return unless cred && location_id && cred.location_id
    return if location_id == cred.location_id
    return if cred.restaurants.where(location_id: cred.location_id).exists?

    errors.add(:base, "Link #{cred.location&.name || 'this login'}'s own restaurant first")
  end

  def location_in_credentials_organization
    return unless location && supplier_credential
    return if location.organization_id == supplier_credential.organization_id

    errors.add(:location, "must belong to the connection's organization")
  end

  def credential_belongs_to_owner_or_manager
    return unless supplier_credential

    role = supplier_credential.user&.membership_for(supplier_credential.organization)&.role
    return if %w[owner manager].include?(role)

    errors.add(:base, "Only owners and managers can match restaurants to a supplier login")
  end
end
