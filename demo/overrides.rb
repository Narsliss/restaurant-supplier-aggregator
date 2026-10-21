# frozen_string_literal: true

module DemoMode
  # The two places a demo screen would otherwise depend on a live supplier.
  # Prepended on each code reload; with the switch off both call the original.
  module Overrides
    def self.install!
      SupplierCredential.prepend(CredentialConnected) unless SupplierCredential <= CredentialConnected
      return if Suppliers::RestaurantMatching <= StoredRestaurants

      Suppliers::RestaurantMatching.prepend(StoredRestaurants)
    end

    # No session ever gets refreshed on the demo, so an active login counts as
    # connected: no "Disconnected", no "Session expired — click Validate".
    module CredentialConnected
      def session_valid?
        return active? if DemoMode.enabled?

        super
      end
    end

    # "Restaurants on this login" asks the supplier live. On the demo it lists
    # what the login already knows: its remembered list, its matches, or else
    # one supplier account per restaurant in the organization.
    module StoredRestaurants
      def restaurants
        return super unless DemoMode.enabled?

        DemoMode::Overrides.demo_restaurants(@credential)
      end
    end

    def self.demo_restaurants(credential)
      stored = Array(credential.supplier_restaurants).map(&:symbolize_keys)
      return stored.map { |r| r.slice(:id, :name, :meta) } if stored.any?

      matched = credential.restaurants.map do |r|
        { id: r.supplier_account_id.to_s, name: r.account_name, meta: r.account_meta || {} }
      end
      return matched if matched.any?

      Location.where(organization_id: credential.organization_id).order(:name).map do |location|
        { id: "DEMO-#{location.id}", name: location.name, meta: {} }
      end
    end
  end
end
