module OrdersHelper
  # The bold "YOU ARE ORDERING FOR <restaurant>" banner — only for people who
  # can switch restaurants in EnPlace (owners/managers with more than one).
  # A chef ordering for their one restaurant never needs the reminder, so it
  # takes up no room on their screen.
  def ordering_for_banner(location:, viewing_location: nil, compact: false)
    return unless can_order_for_several_locations?

    render "shared/ordering_for_banner", location: location, viewing_location: viewing_location, compact: compact
  end

  def can_order_for_several_locations?
    return false if chef?

    accessible_locations.limit(2).count > 1
  end

  # "US Foods isn't set up for Noche yet" — shown in the order builder only
  # when something needs fixing (success is silent). Owners/managers only.
  def supplier_setup_notice(location:, compact: false)
    logins = unplaced_supplier_logins(location)
    return if logins.empty?

    render "shared/supplier_setup_notice", logins: logins, location: location, compact: compact
  end

  # The user's multi-restaurant picker logins that list a restaurant the
  # automatic linker couldn't place, and don't order for +location+ yet (nor
  # does another login of theirs for that supplier).
  def unplaced_supplier_logins(location)
    return [] unless location && can_order_for_several_locations?

    mine = current_user.supplier_credentials.where(organization_id: location.organization_id)
    serving = mine.serving_location(location).pluck(:supplier_id)
    mine.includes(:supplier, :restaurants).select do |cred|
      next false if serving.include?(cred.supplier_id)

      standing = Suppliers::RestaurantLinks.new(cred, accessible_locations.to_a)
      standing.applicable? && standing.snapshot.size > 1 && standing.unplaced.any?
    end
  end
  # Human label + tone for a supplier exception type (see UsFoodsExceptionParser).
  EXCEPTION_TYPE_LABELS = {
    "out_of_stock" => "Out of stock",
    "short_fill" => "Short-filled",
    "substituted" => "Substituted",
    "removed" => "Removed",
    "price_change" => "Price changed"
  }.freeze

  def exception_type_label(type)
    EXCEPTION_TYPE_LABELS[type.to_s] || "Issue"
  end

  # Share of what the order WOULD have cost that was saved:
  #   savings / (savings + spent)
  # Mathematically bounded to 100%, unlike savings/spent ("dollars saved per
  # dollar spent"), which reported 101% — and, filtered to one supplier,
  # 300% — off a single bad savings row.
  def savings_percentage(savings, spent)
    savings = savings.to_f
    spent = spent.to_f
    would_have_paid = savings + spent
    return nil unless would_have_paid.positive? && savings.positive?

    (savings / would_have_paid) * 100
  end
end
