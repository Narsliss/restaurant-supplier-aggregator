module Suppliers
  # Which of the ordering user's connections places / verifies / checks an order.
  #
  # Unchanged for a user whose logins for that supplier cover one restaurant
  # (every one-location chef, every single-restaurant owner): the same query as
  # before. When they cover several — an owner with a separate login per
  # restaurant (Performance), or one login matched to several restaurants —
  # only a connection that serves the order's location qualifies (attached to
  # it, or matched to it), so an order can never go out through another
  # restaurant's login. No such connection: nothing is returned and the order
  # fails loudly.
  module OrderCredential
    # statuses: nil means any status.
    def self.scope(order, statuses: %w[active])
      self.for(user: order.user, supplier: order.supplier, location_id: order.location_id, statuses: statuses)
    end

    # Same rule without an Order record (e.g. the pre-order check).
    def self.for(user:, supplier:, location_id:, statuses: %w[active])
      all = user.supplier_credentials.where(supplier: supplier)
      base = statuses ? all.where(status: statuses) : all
      return base unless SupplierCredential.spans_restaurants?(all)

      base.serving_location(location_id)
    end
  end
end
