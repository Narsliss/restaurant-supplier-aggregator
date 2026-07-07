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
end
