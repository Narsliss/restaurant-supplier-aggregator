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

  # Scopes
  scope :in_stock, -> { where(in_stock: true) }
  scope :out_of_stock, -> { where(in_stock: false) }
  scope :with_price, -> { where.not(price: nil) }
  scope :by_position, -> { order(:position) }
  scope :linked, -> { where.not(supplier_product_id: nil) }
  scope :unlinked, -> { where(supplier_product_id: nil) }

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

  def per_unit_price
    return nil unless price && parsed_pack_size[:parseable]
    return nil if parsed_pack_size[:normalized_quantity] <= 0

    (price / parsed_pack_size[:normalized_quantity]).round(4)
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

  # Stock status: prefer the linked supplier_product (updated during imports)
  # over the list item's own in_stock column (only set at list sync time).
  def in_stock
    supplier_product ? supplier_product.in_stock : super
  end

  def in_stock?
    !!in_stock
  end

  # Price display
  def formatted_price
    return 'N/A' unless price

    "$#{'%.2f' % price}"
  end

  def price_with_pack
    parts = [formatted_price]
    parts << pack_size if pack_size.present?
    parts.join(' / ')
  end

  private

  def sanitize_sql_like(string)
    string.gsub(/[%_\\]/) { |m| "\\#{m}" }
  end
end
