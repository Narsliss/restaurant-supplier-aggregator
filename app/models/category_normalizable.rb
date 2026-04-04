module CategoryNormalizable
  # Maps raw Product.category values to normalized display names.
  # Add entries here when new overlapping categories appear in scrapes.
  # Keys are downcased for case-insensitive lookup.
  CATEGORY_MAP = {
    # Produce variants
    "fresh produce"           => "Produce",
    "fresh fruits"            => "Produce",
    "fresh vegetables"        => "Produce",
    "herbs"                   => "Produce",
    # Dairy variants
    "dairy and eggs"          => "Dairy",
    "dairy products"          => "Dairy",
    # Frozen
    "frozen foods"            => "Frozen",
    # Dry Goods
    "dry storage"             => "Dry Goods",
    # Cleaning — consolidate all supplier naming variants
    "cleaning & sanitation"   => "Cleaning & Sanitation",
    "chemicals & cleaners"    => "Cleaning & Sanitation",
    "chemicals & cleaning agents" => "Cleaning & Sanitation",
    "chemicals and cleaning"  => "Cleaning & Sanitation",
    # Canned — consolidate supplier naming variants
    "canned and dry"          => "Canned & Jarred",
    "canned goods"            => "Canned & Jarred",
    # Meat — merge subcategory-level raw values
    "beef"                    => "Meat",
    "pork"                    => "Meat",
    "lamb"                    => "Meat",
    "veal"                    => "Meat",
    # Prepared foods → Meat (typically proteins/entrees)
    "prepared foods and deli" => "Meat",
  }.freeze

  def self.normalize(raw_category)
    return nil if raw_category.blank?
    key = raw_category.downcase.strip
    CATEGORY_MAP[key] || raw_category.strip.titleize
  end
end
