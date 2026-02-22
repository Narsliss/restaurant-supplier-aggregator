module CategoryNormalizable
  # Maps raw Product.category values to normalized display names.
  # Add entries here when new overlapping categories appear in scrapes.
  CATEGORY_MAP = {
    "Fresh Produce"         => "Produce",
    "Fresh Fruits"          => "Produce",
    "Fresh Vegetables"      => "Produce",
    "Herbs"                 => "Produce",
    "Dairy And Eggs"        => "Dairy",
    "Frozen Foods"          => "Frozen",
    "Dry Storage"           => "Dry Goods",
    "Cleaning & Sanitation" => "Chemicals & Cleaners",
  }.freeze

  def self.normalize(raw_category)
    return nil if raw_category.blank?
    CATEGORY_MAP[raw_category] || raw_category
  end
end
