class SupplierListItem < ApplicationRecord
  # Associations
  belongs_to :supplier_list
  belongs_to :supplier_product, optional: true
  has_many :product_match_items, dependent: :destroy
  has_many :product_matches, through: :product_match_items

  # Validations
  validates :name, presence: true
  validates :sku, uniqueness: { scope: :supplier_list_id, allow_blank: true }
  validates :price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # Source constants
  SOURCES = %w[order_guide catalog_search].freeze

  # Price change tracking
  PRICE_CHANGE_DISPLAY_WINDOW = 48.hours

  # Scopes
  scope :in_stock, -> { where(in_stock: true) }
  scope :out_of_stock, -> { where(in_stock: false) }
  scope :with_price, -> { where.not(price: nil) }
  scope :by_position, -> { order(:position) }
  scope :linked, -> { where.not(supplier_product_id: nil) }
  scope :unlinked, -> { where(supplier_product_id: nil) }
  scope :from_order_guide, -> { where(source: 'order_guide') }
  scope :from_catalog_search, -> { where(source: 'catalog_search') }

  def catalog_search?
    source == 'catalog_search'
  end

  # Delegations
  delegate :supplier, to: :supplier_list
  delegate :supplier_credential, to: :supplier_list

  # Link to an existing SupplierProduct, trying (in order):
  #   1. Exact SKU match
  #   2. Exact name match (case-insensitive)
  #   3. Prefix name match — some platforms (e.g. Cut+Dry / WCW) append brand
  #      names in catalog but not in the order guide, so "Cherries - Amarene In
  #      Syrup" should match "Cherries - Amarene In Syrup Gelatech".
  # If no match is found and we have enough data, create a SupplierProduct so
  # the item can be included in orders.
  def link_to_supplier_product!
    return if supplier_product_id.present?

    sid = supplier_list.supplier_id

    # 1. SKU match
    sp = SupplierProduct.find_by(supplier_id: sid, supplier_sku: sku) if sku.present?

    if sp.nil? && name.present?
      clean_name = name.downcase.strip

      # 2. Exact name match (case-insensitive)
      sp = SupplierProduct.where(supplier_id: sid)
             .where('LOWER(supplier_name) = ?', clean_name)
             .first

      # 3. Prefix match — list name is a prefix of catalog name (brand appended)
      #    Only if name is long enough to avoid false positives
      if sp.nil? && clean_name.length >= 10
        sp = SupplierProduct.where(supplier_id: sid)
               .where('LOWER(supplier_name) LIKE ?', "#{sanitize_sql_like(clean_name)}%")
               .order(:supplier_name)
               .first
      end
    end

    # 4. Create from list item data so orders aren't silently dropped
    if sp.nil? && name.present? && price.present?
      sp = SupplierProduct.create!(
        supplier_id: sid,
        supplier_sku: sku.presence || "LIST-#{id}",
        supplier_name: name,
        current_price: price,
        pack_size: pack_size,
        piece_price: piece_price,
        piece_pack_size: piece_pack_size,
        in_stock: in_stock,
        price_updated_at: Time.current,
        last_scraped_at: Time.current
      )
    end

    update!(supplier_product_id: sp.id) if sp
  end

  # Per-unit price comparison (delegates to UnitParser)
  def parsed_pack_size
    @parsed_pack_size ||= UnitParser.parse(pack_size)
  end

  # Returns the per-unit price in the normalized base unit (oz, fl oz, each, etc.)
  #
  # When price_unit is set (e.g., "lb"), the stored price IS already per that unit,
  # so we just convert to the normalized base unit without dividing by pack quantity.
  # Example: tenderloin at $12.50/lb → $12.50 / 16 oz/lb = $0.78/oz
  #
  # When price_unit is nil, the price is for the whole pack (default behavior).
  # Example: $125.00 for a 10 LB case → $125.00 / 160 oz = $0.78/oz
  def per_unit_price
    return nil unless price

    effective_price_unit = price_unit.presence || inferred_price_unit
    if effective_price_unit.present?
      per_unit_price_from_unit_pricing(effective_price_unit)
    else
      per_unit_price_from_case_pricing
    end
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

  # Per-unit price for a single PIECE within a case pack.
  # Uses the per-piece quantity extracted from the case pack size.
  # Example: "12x10.5 Oz BC" at piece_price=$7.98 → $7.98 / 10.5 oz = $0.76/oz
  def piece_per_unit_price
    return nil unless piece_price.present? && piece_price > 0

    per_piece = UnitParser.per_piece_normalized(pack_size)
    if per_piece && per_piece[:quantity] > 0
      (piece_price / per_piece[:quantity]).round(4)
    end
  end

  def formatted_piece_per_unit_price
    per_piece = UnitParser.per_piece_normalized(pack_size)
    return nil unless per_piece
    UnitParser.format_per_unit(piece_per_unit_price, per_piece[:unit])
  end

  # Estimated total price for the full pack.
  # For per-unit pricing: price × quantity in that unit.
  # For case pricing: the price itself.
  def estimated_total_price
    UnitParser.estimated_total(price, price_unit.presence || inferred_price_unit, pack_size)
  end

  # Price change detection (mirrors SupplierProduct pattern)
  def price_changed?
    price.present? && previous_price.present? && price != previous_price
  end

  def price_increased?
    price_changed? && price > previous_price
  end

  def price_decreased?
    price_changed? && price < previous_price
  end

  def price_change_recent?
    price_changed? && price_updated_at.present? && price_updated_at > PRICE_CHANGE_DISPLAY_WINDOW.ago
  end

  def price_direction
    return nil unless price_change_recent?

    price_increased? ? :up : :down
  end

  # Stock status: prefer the linked supplier_product (updated during imports)
  # over the list item's own in_stock column (only set at list sync time).
  def in_stock
    supplier_product ? supplier_product.in_stock : super
  end

  def in_stock?
    !!in_stock
  end

  # Price display — shows "/lb", "/oz" etc. when price is per-unit
  def formatted_price
    return 'N/A' unless price

    base = "$#{'%.2f' % price}"
    effective_unit = price_unit.presence || inferred_price_unit
    if effective_unit.present?
      unit_display = effective_unit.upcase
      "#{base}/#{unit_display}"
    else
      base
    end
  end

  def price_with_pack
    parts = [formatted_price]
    parts << pack_size if pack_size.present?
    parts.join(' / ')
  end

  private

  # Detect per-unit pricing from pack_size patterns.
  # Variable-weight indicators (common for meat/seafood):
  #   "15 LB+"          → + suffix means approximate weight, priced per lb
  #   "12LB AVG"        → AVG means average weight, priced per lb
  #   "4/15 LB CS"      → multi-piece case with LB weight, priced per lb
  def inferred_price_unit
    return nil unless pack_size.present?

    # "15 LB+" or "5 OZ+" — plus sign means variable weight
    if pack_size =~ /\d+\.?\d*\s*(LB|OZ|KG)\s*\+/i
      return $1.downcase
    end

    # "12LB AVG" — average weight means per-unit pricing
    if pack_size =~ /\d+\.?\d*\s*(LB|OZ|KG)\s+AVG/i
      return $1.downcase
    end

    # "4/15 LB CS" — multi-piece LB case pattern (N/N LB CS|Case)
    # The N/N with LB + case suffix indicates per-lb pricing for portioned meat
    if pack_size =~ /\d+\s*\/\s*\d+\s*(LB)\s*(CS|Case)/i
      return $1.downcase
    end

    nil
  end

  # Price is already per the stored price_unit (e.g., $12.50/lb).
  # Convert to the pack's normalized base unit.
  def per_unit_price_from_unit_pricing(unit = price_unit)
    unit_key = UnitParser.normalize_unit_key(unit)

    # Find how many base units (oz, fl oz, each) one price_unit represents
    conversion = UnitParser::WEIGHT_TO_OZ[unit_key] ||
                 UnitParser::VOLUME_TO_FL_OZ[unit_key] ||
                 UnitParser::COUNT_TO_EACH[unit_key]

    return nil unless conversion && conversion > 0

    (price / conversion).round(4)
  end

  # Price is for the whole pack — divide by total normalized quantity.
  def per_unit_price_from_case_pricing
    return nil unless parsed_pack_size[:parseable]
    return nil if parsed_pack_size[:normalized_quantity] <= 0

    (price / parsed_pack_size[:normalized_quantity]).round(4)
  end

  def sanitize_sql_like(string)
    string.gsub(/[%_\\]/) { |m| "\\#{m}" }
  end
end
