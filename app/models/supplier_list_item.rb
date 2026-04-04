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

  # Container-type price_units that mean "price is for the whole pack" —
  # these should fall through to case pricing, not unit conversion.
  CONTAINER_PRICE_UNITS = Set.new(%w[cs case bag box unit tray bucket jar]).freeze

  # Returns the per-unit price in the normalized base unit (oz, fl oz, each, etc.)
  #
  # When price_unit is set (e.g., "lb"), the stored price IS already per that unit,
  # so we just convert to the normalized base unit without dividing by pack quantity.
  # Example: tenderloin at $12.50/lb → $12.50 / 16 oz/lb = $0.78/oz
  #
  # When price_unit is nil, the price is for the whole pack (default behavior).
  # Example: $125.00 for a 10 LB case → $125.00 / 160 oz = $0.78/oz
  def per_unit_price
    return nil unless effective_price

    effective_price_unit = price_unit.presence || inferred_price_unit
    if effective_price_unit.present?
      unit_key = UnitParser.normalize_unit_key(effective_price_unit)

      # Container types (CS, CASE, BAG, BOX, etc.) mean the price is for the
      # whole pack — treat as case pricing. Exception: variable-weight items
      # (pack_size contains AVG, UP, or +) are actually per-lb despite the
      # container label (common with Sysco meat items).
      if CONTAINER_PRICE_UNITS.include?(unit_key)
        inferred = inferred_price_unit
        return per_unit_price_from_unit_pricing(inferred) if inferred.present?
        return per_unit_price_from_case_pricing
      end

      # "each" on a weight/volume item (e.g., $8.50/each for 1qt) means
      # the price is per pack unit — treat as case pricing.
      # Exception: if inferred_price_unit detects per-lb (e.g., PPO "EACH"
      # items with # weights), use per-lb pricing instead.
      if unit_key == "each" && normalized_unit.present? && normalized_unit != "each"
        inferred = inferred_price_unit
        return per_unit_price_from_unit_pricing(inferred) if inferred.present?
        return per_unit_price_from_case_pricing
      end

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
    effective_unit = price_unit.presence || inferred_price_unit
    if effective_unit.present?
      unit_key = UnitParser.normalize_unit_key(effective_unit)

      # Container types — price IS the total already
      if CONTAINER_PRICE_UNITS.include?(unit_key)
        inferred = inferred_price_unit
        return UnitParser.estimated_total(effective_price, inferred, pack_size) if inferred.present?
        return effective_price
      end

      # "each" on weight/volume — price is per item, pack describes one item,
      # so the price IS the total for that item.
      # Exception: if inferred_price_unit detects per-lb, compute the total.
      if unit_key == "each" && normalized_unit.present? && normalized_unit != "each"
        inferred = inferred_price_unit
        return UnitParser.estimated_total(effective_price, inferred, pack_size) if inferred.present?
        return effective_price
      end
    end

    # Per-piece pricing (Piece/PC suffix): multiply by case count.
    # "12x1 QT Piece" at $2.46/piece → $2.46 × 12 = $29.52 case total.
    if pack_size.present? && pack_size.match?(/\bPiece\b|\bPC\b(?!\s*\()/i)
      per_piece = UnitParser.per_piece_normalized(pack_size)
      if per_piece && per_piece[:quantity] > 0 && parsed_pack_size[:parseable]
        case_count = (parsed_pack_size[:normalized_quantity] / per_piece[:quantity]).round
        return (effective_price * case_count).round(2) if case_count > 1
      end
    end

    UnitParser.estimated_total(effective_price, effective_unit, pack_size)
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

  # Fall back to the linked supplier_product's current_price when the list
  # item's own price column is nil (happens when the order-guide scraper
  # misses a price that the catalog scraper captured on the product page).
  def effective_price
    price.presence || supplier_product&.current_price
  end

  # Price display — shows "/lb", "/oz" etc. when price is per-unit.
  # Container types (CS, CASE, etc.) are suppressed since case pricing is the default.
  def formatted_price
    ep = effective_price
    return 'N/A' unless ep

    base = "$#{'%.2f' % ep}"
    effective_unit = price_unit.presence || inferred_price_unit
    if effective_unit.present?
      unit_key = UnitParser.normalize_unit_key(effective_unit)
      # Don't show "/CS", "/CASE", etc. — case pricing is the default display
      # For "each" on weight items with inferred per-lb, show "/LB" instead of "/EACH"
      unless CONTAINER_PRICE_UNITS.include?(unit_key)
        inferred = inferred_price_unit if unit_key == "each"
        unit_display = (inferred || effective_unit).upcase
        "#{base}/#{unit_display}"
      else
        # If pack_size has variable-weight indicators, show the inferred unit
        inferred = inferred_price_unit
        if inferred.present?
          "#{base}/#{inferred.upcase}"
        else
          base
        end
      end
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
  #   "5LB UP AVG"      → UP + AVG also indicates per-lb
  #   "10#avg"          → pound-sign with AVG, same meaning
  #   "5#UP"            → pound-sign with UP (minimum weight), priced per lb
  def inferred_price_unit
    return nil unless pack_size.present?

    # When the list item has no own price and falls back to the supplier
    # product's current_price (a case/catalog price), skip variable-weight
    # inference for suppliers that return case prices. The fallback price
    # is the total case cost, not a per-unit price.
    # Suppliers with case_pricing=false (e.g., US Foods) store per-unit
    # prices even in the catalog, so inference still applies for them.
    return nil if price.blank? && supplier&.case_pricing?

    # PPO "Case - 75# AVG" — the "Case -" prefix means the price is for
    # the whole case, not per-lb. Without this guard the # AVG regex below
    # would incorrectly treat $560 as $560/lb.
    return nil if pack_size =~ /\ACase\s*-/i

    # "15 LB+" or "5 OZ+" — plus sign means variable weight
    if pack_size =~ /\d+\.?\d*\s*(LB|OZ|KG)\s*\+/i
      return $1.downcase
    end

    # "10#+" — pound-sign with plus
    if pack_size =~ /\d+\.?\d*\s*#\s*\+/i
      return "lb"
    end

    # "12LB AVG" or "5LB UP AVG" — average weight means per-unit pricing
    # Allow optional words (UP, etc.) between the unit and AVG.
    if pack_size =~ /\d+\.?\d*\s*(LB|OZ|KG)\s+(?:\w+\s+)?AVG/i
      return $1.downcase
    end

    # "10#avg" or "5# AVG" — pound-sign with AVG
    if pack_size =~ /\d+\.?\d*\s*#\s*AVG/i
      return "lb"
    end

    # "5#UP" or "5# UP" — pound-sign with UP (minimum weight)
    if pack_size =~ /\d+\.?\d*\s*#\s*UP/i
      return "lb"
    end

    # PPO "EACH" items with pound weights (# or LB) are priced per-lb,
    # not per-piece. E.g., "EACH - 1-5#" at $7.60 = $7.60/lb for a ~5 lb piece.
    # Volume/count items (QT, KG, CT) are genuine per-each pricing.
    effective_unit = price_unit.presence
    if effective_unit.present? && UnitParser.normalize_unit_key(effective_unit) == "each"
      if pack_size =~ /\d+\s*(?:#|lb\b)/i
        return "lb"
      end
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

    (effective_price / conversion).round(4)
  end

  # Price is for the whole pack — divide by total normalized quantity.
  # Exception: "Piece" or standalone "PC" in pack_size means the price is
  # per-piece (e.g., "12x1 QT Piece" at $2.46 = $2.46 for 1 QT, not 12 QT).
  def per_unit_price_from_case_pricing
    return nil unless parsed_pack_size[:parseable]
    return nil if parsed_pack_size[:normalized_quantity] <= 0

    # Detect per-piece pricing: "Piece" or standalone "PC" (not in parens like "(16 PER Case)")
    if pack_size.present? && pack_size.match?(/\bPiece\b|\bPC\b(?!\s*\()/i)
      per_piece = UnitParser.per_piece_normalized(pack_size)
      if per_piece && per_piece[:quantity] > 0
        return (effective_price / per_piece[:quantity]).round(4)
      end
    end

    (effective_price / parsed_pack_size[:normalized_quantity]).round(4)
  end

  def sanitize_sql_like(string)
    string.gsub(/[%_\\]/) { |m| "\\#{m}" }
  end
end
