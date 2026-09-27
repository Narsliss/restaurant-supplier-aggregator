# Links owners' multi-restaurant supplier logins to their EnPlace restaurants
# (Suppliers::RestaurantAutoLinker — certain matches only, silent on success).
#   perform(credential_id)              one login (after it connects)
#   perform(nil, organization_id: id)   every login in an organization (a restaurant was added)
#   perform                             every login (daily: suppliers often set up a new
#                                       restaurant's account days after it exists in EnPlace)
# Only owner/manager logins on picker suppliers in organizations with 2+
# restaurants do anything; the linker checks that before calling a supplier.
class AutoLinkSupplierRestaurantsJob < ApplicationJob
  queue_as :low

  def perform(credential_id = nil, organization_id: nil)
    scope = SupplierCredential.joins(:supplier)
                              .where(suppliers: { code: SupplierCredential::SWITCHABLE_SUPPLIER_CODES })
                              .where(status: 'active')
    scope = scope.where(id: credential_id) if credential_id
    scope = scope.where(organization_id: organization_id) if organization_id
    scope.includes(:supplier, :user, :organization).find_each do |credential|
      Suppliers::RestaurantAutoLinker.run_safely(credential)
    end
  end
end
