class SupplierProduct < ApplicationRecord
  include UnitComparable

  # Associations
  belongs_to :product, optional: true
  belongs_to :supplier
  has_many :order_items, dependent: :nullify
  has_many :favorite_products, dependent: :destroy
  has_many :supplier_list_items, dependent: :nullify

  # Mirrored product thumbnail (~200px JPEG on Cloudflare R2). Populated lazily
  # by MirrorProductImageJob from image_source_url. See ProductImagesHelper.
  has_one_attached :thumbnail

  # Validations
  validates :supplier_sku, presence: true
  validates :supplier_sku, uniqueness: { scope: :supplier_id }
  validates :supplier_name, presence: true
  validates :current_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :minimum_quantity, numericality: { greater_than: 0 }, allow_nil: true
  validates :maximum_quantity, numericality: { greater_than: 0 }, allow_nil: true

  # Configurable threshold: a product must be missing from this many consecutive
  # full imports before it is marked as discontinued. This prevents false positives
  # from partial scrapes, network failures, or paginated search results.
  DISCONTINUE_AFTER_MISSES = 3

  # Scopes
  scope :in_stock, -> { where(in_stock: true) }
  scope :out_of_stock, -> { where(in_stock: false) }
  scope :with_price, -> { where.not(current_price: nil) }
  scope :stale, -> { where('last_scraped_at < ? OR last_scraped_at IS NULL', 24.hours.ago) }
  scope :price_changed, -> { where.not(previous_price: nil).where('current_price != previous_price') }
  scope :available, -> { where(discontinued: false) }
  scope :discontinued, -> { where(discontinued: true) }
  scope :at_risk, -> { where('consecutive_misses > 0 AND discontinued = ?', false) }

  # Scope products by user's validated suppliers
  scope :for_user, ->(user) { where(supplier_id: user.validated_supplier_ids) }
  scope :for_suppliers, ->(supplier_ids) { where(supplier_id: supplier_ids) }

  # Methods
  def in_stock?
    in_stock
  end

  def out_of_stock?
    !in_stock
  end

  def price_changed?
    previous_price.present? && current_price != previous_price
  end

  def price_change_percent
    return nil unless price_changed? && previous_price.to_f > 0

    ((current_price - previous_price) / previous_price * 100).round(2)
  end

  def price_increased?
    price_changed? && current_price > previous_price
  end

  def price_decreased?
    price_changed? && current_price < previous_price
  end

  def update_price!(new_price, in_stock: true)
    update!(
      previous_price: current_price,
      current_price: new_price,
      in_stock: in_stock,
      price_updated_at: Time.current,
      last_scraped_at: Time.current
    )
  end

  def stale?
    last_scraped_at.nil? || last_scraped_at < 24.hours.ago
  end

  def discontinued?
    discontinued
  end

  # Record that this product was NOT found in a supplier catalog scrape.
  # Increments the miss counter; marks as discontinued once the threshold is reached.
  def record_miss!
    new_misses = consecutive_misses + 1
    attrs = { consecutive_misses: new_misses }

    if new_misses >= DISCONTINUE_AFTER_MISSES && !discontinued
      attrs[:discontinued] = true
      attrs[:discontinued_at] = Time.current
      attrs[:in_stock] = false
      Rails.logger.info "[SupplierProduct] Discontinued #{supplier_name} (SKU: #{supplier_sku}) after #{new_misses} consecutive misses"
    end

    update!(attrs)
  end

  # Product reappeared in a scrape — reset discontinuation state.
  def record_seen!
    return if consecutive_misses.zero? && !discontinued

    attrs = { consecutive_misses: 0 }
    if discontinued
      attrs[:discontinued] = false
      attrs[:discontinued_at] = nil
      Rails.logger.info "[SupplierProduct] Reinstated #{supplier_name} (SKU: #{supplier_sku}) — product reappeared in catalog"
    end

    update!(attrs)
  end

  # Pack size parsing and per-unit pricing

  def parsed_pack_size
    @parsed_pack_size ||= UnitParser.parse(pack_size)
  end

  # Case-equivalent price for a product whose stored price may be per-unit.
  # Catch-weight items (e.g. US Foods pork at $2.00/LB, price_unit "LB") store
  # the per-pound price in current_price; order lines are priced per case, so
  # comparing or charging the raw figure understates the case by ~50x.
  # Only weight/volume price units convert — count units ("EA", "CS") mean the
  # price already covers the pack. Unparseable pack sizes return the raw price.
  def estimated_case_price(price: current_price, unit: price_unit)
    return price if price.blank? || unit.blank?

    unit_key = UnitParser.normalize_unit_key(unit)
    return price unless UnitParser::WEIGHT_TO_OZ.key?(unit_key) || UnitParser::VOLUME_TO_FL_OZ.key?(unit_key)

    UnitParser.estimated_total(price, unit_key, pack_size) || price
  end

  # True when the stored price is per-weight (catch-weight style billing).
  def priced_per_weight?
    return false if price_unit.blank?

    UnitParser::WEIGHT_TO_OZ.key?(UnitParser.normalize_unit_key(price_unit))
  end

  # UnitComparable inputs
  def comparison_price
    current_price
  end

  def comparison_name
    supplier_name
  end

  def per_unit_price
    return nil unless current_price

    # When the stored price is per-unit (catch-weight "$2.00/LB"), the
    # per-normalized-unit price comes straight from the unit factor —
    # dividing by the pack quantity would treat $2.00 as the case price.
    if price_unit.present?
      unit_key = UnitParser.normalize_unit_key(price_unit)
      factor = UnitParser::WEIGHT_TO_OZ[unit_key] || UnitParser::VOLUME_TO_FL_OZ[unit_key]
      return (current_price / factor).round(4) if factor
    end

    return nil unless parsed_pack_size[:parseable] && parsed_pack_size[:normalized_quantity] > 0

    (current_price / parsed_pack_size[:normalized_quantity]).round(4)
  end

  def normalized_unit
    parsed_pack_size[:parseable] ? parsed_pack_size[:normalized_unit] : nil
  end

  def comparable_with?(other)
    return false unless parsed_pack_size[:parseable] && other.parsed_pack_size[:parseable]

    normalized_unit == other.normalized_unit
  end

  def formatted_per_unit_price
    UnitParser.format_per_unit(per_unit_price, normalized_unit)
  end

  def line_total(quantity)
    return nil unless current_price

    current_price * quantity
  end

  def meets_minimum?(quantity)
    minimum_quantity.nil? || quantity >= minimum_quantity
  end

  def within_maximum?(quantity)
    maximum_quantity.nil? || quantity <= maximum_quantity
  end

  def quantity_valid?(quantity)
    meets_minimum?(quantity) && within_maximum?(quantity)
  end

  # Build a hash of { normalized_name => [SupplierProduct, ...] } for catalog search.
  # Called on an ActiveRecord::Relation (e.g., SupplierProduct.where(...).index_by_normalized_name).
  def self.index_by_normalized_name
    index = Hash.new { |h, k| h[k] = [] }
    find_each do |sp|
      name = sp.product&.normalized_name || ProductNormalizer.normalize(sp.supplier_name)
      index[name] << sp if name.present?
    end
    index
  end
end
