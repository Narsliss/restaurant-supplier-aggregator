class SupplierListItem < ApplicationRecord
  include UnitComparable

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

  # Link to an existing SupplierProduct.
  #
  # When the SLI has a SKU, only match by SKU — the SKU is the supplier's
  # canonical identifier. Falling back to name matching is unsafe: adjacent
  # products often share name prefixes ("Spinach - Flat Leaf" vs
  # "Spinach - Flat Leaf Each", off-by-one SKUs) and the linker would grab the
  # wrong neighbor. If no SKU match exists yet, leave unlinked — the catalog
  # importer's back-link sweep (ImportSupplierProductsService#import_batch)
  # will pick it up when the matching SP gets scraped.
  #
  # When the SLI has NO SKU (rare legacy case), fall back to name matching:
  # exact case-insensitive, then prefix (some platforms append brand names in
  # catalog but not in the order guide).
  #
  # If still no match and we have enough data, create a SupplierProduct so
  # orders aren't silently dropped. The catalog scraper will upsert this row
  # when it later sees the same SKU.
  def link_to_supplier_product!
    return if supplier_product_id.present?

    sid = supplier_list.supplier_id

    if sku.present?
      sp = SupplierProduct.find_by(supplier_id: sid, supplier_sku: sku)
    elsif name.present?
      clean_name = name.downcase.strip

      sp = SupplierProduct.where(supplier_id: sid)
             .where('LOWER(supplier_name) = ?', clean_name)
             .first

      if sp.nil? && clean_name.length >= 10
        sp = SupplierProduct.where(supplier_id: sid)
               .where('LOWER(supplier_name) LIKE ?', "#{sanitize_sql_like(clean_name)}%")
               .order(:supplier_name)
               .first
      end
    end

    if sp.nil? && name.present? && price.present?
      effective_sku = sku.presence || "LIST-#{id}"
      sp = upsert_stub_supplier_product!(sid, effective_sku)
    end

    update!(supplier_product_id: sp.id) if sp
  end

  # Two concurrent list/email imports for the same supplier can both miss the
  # find_by above and race to create the same (supplier_id, supplier_sku) pair.
  # Rails uniqueness validation raises RecordInvalid; the DB unique index raises
  # RecordNotUnique. Treat either as "someone else won — go re-find their row."
  def upsert_stub_supplier_product!(sid, effective_sku)
    SupplierProduct.create!(
      supplier_id: sid,
      supplier_sku: effective_sku,
      supplier_name: name,
      current_price: price,
      pack_size: pack_size,
      piece_price: piece_price,
      piece_pack_size: piece_pack_size,
      in_stock: in_stock,
      price_updated_at: Time.current,
      last_scraped_at: Time.current
    )
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors[:supplier_sku].any?
    SupplierProduct.find_by(supplier_id: sid, supplier_sku: effective_sku) or raise
  rescue ActiveRecord::RecordNotUnique
    SupplierProduct.find_by(supplier_id: sid, supplier_sku: effective_sku) or raise
  end

  # Per-unit price comparison (delegates to UnitParser)
  # The chef-set weight for this exact pack, or nil when none exists or when
  # the supplier has changed the pack out from under it. A stale override goes
  # dormant rather than deleting itself: the chef still sees what they set and
  # why it is paused, and decides.
  def unit_override
    return @unit_override if defined?(@unit_override)

    key = sku.presence || supplier_product&.supplier_sku
    @unit_override = key.present? ? supplier_list&.unit_overrides_by_sku&.[](key) : nil
  end

  def unit_override_stale?
    ov = unit_override
    ov.present? && ov.stale_against?(pack_size.presence || supplier_product&.pack_size)
  end

  def chef_pack_weight_oz
    ov = unit_override
    return nil if ov.blank? || unit_override_stale?

    ov.total_oz_for(pack_size.presence || supplier_product&.pack_size)
  end

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

    effective_price_unit = stated_price_unit || inferred_price_unit
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

  # Compute per-lb price from a case price when the pack is weight-based.
  # Used in the view to show "$22.58/LB ~$135.48" for case-priced items
  # that have a parseable lb quantity (e.g., "6LB AVG" at $135.48 → $22.58/lb).
  # Returns nil when price_unit is already set (explicit per-unit pricing) or
  # when inferred_price_unit fires (inference already handles it), or when the
  # pack isn't in lbs.
  def derived_per_lb_price
    return nil if stated_price_unit.present? || inferred_price_unit.present?
    return nil unless effective_price && effective_price > 0

    parsed = parsed_pack_size
    return nil unless parsed[:parseable] && parsed[:unit] == 'lb' && parsed[:quantity] > 0

    (effective_price / parsed[:quantity]).round(2)
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

  # UnitComparable inputs
  def comparison_price
    effective_price
  end

  def comparison_name
    name
  end

  # True when the price is per-weight (explicit or inferred) — catch-weight
  # billing where the invoice depends on delivered weight, so any case total
  # we show is an estimate.
  def priced_per_weight?
    unit = stated_price_unit || inferred_price_unit
    return false if unit.blank?

    UnitParser::WEIGHT_TO_OZ.key?(UnitParser.normalize_unit_key(unit))
  end

  # Display note for catch-weight items: "~est. 49.8 lb @ $2.00/lb".
  # Nil for anything not priced per weight or with an unparseable pack.
  def catch_weight_note
    return nil unless priced_per_weight?
    return nil unless effective_price.present?

    parsed = parsed_pack_size
    return nil unless parsed[:parseable] && parsed[:unit] == "lb"

    qty = parsed[:quantity] % 1 == 0 ? parsed[:quantity].to_i : parsed[:quantity].round(1)
    "~est. #{qty} lb @ #{format('$%.2f', effective_price)}/lb"
  end

  # Estimated total price for the full pack.
  # For per-unit pricing: price × quantity in that unit.
  # For case pricing: the price itself.
  def estimated_total_price
    effective_unit = stated_price_unit || inferred_price_unit
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

    # Same refusal as per_unit_price: a per-weight rate cannot be spread across
    # a pack measured in pieces.
    if effective_unit.present? && !unit_matches_pack?(effective_unit)
      return effective_price
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

  # The unit `effective_price` is actually quoted in, before any inference.
  #
  # effective_price borrows the linked product's price when this row has none,
  # and a catalog-search row was built by copying that same price at search
  # time. The label belongs with the number, but only the price was carried
  # over: a Sysco catch-weight quote is a rate per pound, so a 16 lb case of
  # pork tenderloin quoted at $3.16/lb was read as a $3.16 case and compared at
  # $0.20/lb. The missed-savings report then offered chefs nearly the whole
  # price of their own case as a saving.
  #
  # Returns nil when this row priced itself and said nothing about the unit —
  # callers fall through to inference exactly as before.
  def stated_price_unit
    own = price_unit.presence
    return own if own
    return nil unless price.blank? || catalog_search?

    supplier_product&.price_unit.presence
  end

  # Price display — shows "/lb", "/oz" etc. when price is per-unit.
  # Container types (CS, CASE, etc.) are suppressed since case pricing is the default.
  def formatted_price
    ep = effective_price
    return 'N/A' unless ep

    base = "$#{'%.2f' % ep}"
    effective_unit = stated_price_unit || inferred_price_unit
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
  # Delegates to per-supplier PriceClassifiers for supplier-aware inference.
  def inferred_price_unit
    return @inferred_price_unit if defined?(@inferred_price_unit)
    @inferred_price_unit = PriceClassifiers::Base.for(self).inferred_price_unit
  end

  # A per-weight quote only converts against a weight-based pack.
  #
  # Sysco lists a ribeye as "1x4-5 PC" at $18.35/LB. The pack resolves to pieces,
  # not pounds, so applying the per-pound rate to it invented a $5.16 case cost —
  # cheaper than the $18.35 it reads as today, and cheap enough to win order
  # routing outright. When the price unit and the pack measure different things,
  # we cannot convert; treat the price as the pack total instead of fabricating one.
  def unit_matches_pack?(unit)
    key = UnitParser.normalize_unit_key(unit)
    expected =
      if UnitParser::WEIGHT_TO_OZ.key?(key) then "oz"
      elsif UnitParser::VOLUME_TO_FL_OZ.key?(key) then "fl oz"
      elsif UnitParser::COUNT_TO_EACH.key?(key) then "each"
      end
    return true if expected.nil? # not a convertible unit; existing paths handle it

    normalized_unit == expected
  end

  # Price is already per the stored price_unit (e.g., $12.50/lb).
  # Convert to the pack's normalized base unit.
  def per_unit_price_from_unit_pricing(unit = stated_price_unit)
    return per_unit_price_from_case_pricing unless unit_matches_pack?(unit)

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
