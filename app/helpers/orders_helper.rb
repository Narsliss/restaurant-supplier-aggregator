module OrdersHelper
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
