module Suppliers
  # Where one of an owner's multi-restaurant supplier logins stands: which of
  # their restaurants it orders for, which restaurants on the login couldn't be
  # placed, and which of their restaurants the supplier doesn't list. Used by
  # the Suppliers card, the order builder notice and RestaurantAutoLinker.
  #
  # An owner may already hold the same picker login twice (connected once per
  # restaurant before one-connection-per-supplier existed — Alfio's US Foods at
  # alfios and at D'oro). A restaurant covered by the owner's OTHER connection
  # for the same supplier counts as placed: never offered, never linked twice.
  class RestaurantLinks
    attr_reader :credential, :locations

    def initialize(credential, locations)
      @credential = credential
      @locations = locations
    end

    def applicable?
      credential.switchable_supplier? && (snapshot.size > 1 || links.any?)
    end

    def snapshot
      @snapshot ||= Array(credential.supplier_restaurants)
    end

    def links
      @links ||= credential.restaurants.to_a
    end

    def linked_locations
      links.map(&:location).compact.sort_by(&:name)
    end

    # Restaurants on the login that neither this nor a sibling login links —
    # only while one of the owner's restaurants is still free to link them to.
    def unplaced
      return [] if free_locations.empty?

      taken = links.map(&:supplier_account_id) + sibling_accounts
      snapshot.reject { |r| taken.include?(r['id'].to_s) }
    end

    # The owner's restaurants this login could still be linked to.
    def free_locations
      taken = links.map(&:location_id) + sibling_location_ids
      locations.reject { |l| taken.include?(l.id) }
    end

    # Shown quietly once nothing is left to place.
    def not_listed
      unplaced.empty? ? free_locations : []
    end

    # Restaurants the owner's other connections for this supplier cover:
    # the one each is attached to, plus any it is linked to.
    def sibling_location_ids
      siblings.flat_map { |s| [s.location_id] + s.restaurants.map(&:location_id) }.compact.uniq
    end

    def sibling_accounts
      siblings.flat_map { |s| s.restaurants.map(&:supplier_account_id) }
    end

    private

    def siblings
      @siblings ||= SupplierCredential.where(user_id: credential.user_id, organization_id: credential.organization_id,
                                             supplier_id: credential.supplier_id)
                                      .where.not(id: credential.id)
                                      .includes(:restaurants).to_a
    end
  end
end
