# A pack weight a chef supplied because the supplier never did.
#
# Set Weight in the app, never "override" — the chef overrides nothing the
# supplier said. Where a supplier states a weight we trust it absolutely and
# offer no control at all; this exists for the packs quoted in bushels,
# sheets, pieces and counts, where no weight was given and the comparison
# either fails outright or rests on a guess of ours.
#
# It supplies UnitComparable#comparison_per_oz and NOTHING else. It never
# writes per_unit_price, normalized_unit, price or estimated_total_price, so
# recipe costing, event planning, the supplier portal and order submission —
# all of which read those raw — are immune by construction rather than by
# discipline.
class UnitOverride < ApplicationRecord
  BASES = %w[per_pack per_piece].freeze

  # Sanity rails on the derived price, not on the weight: a chef knows what a
  # bushel weighs, but nobody catches their own decimal point. Rejecting an
  # absurd $/lb is the only automatic check that works in both directions —
  # typing 280 for 28 makes a supplier lose just as wrongly as 2.8 makes it win.
  MIN_PLAUSIBLE_PER_LB = 0.01
  MAX_PLAUSIBLE_PER_LB = 60.00

  belongs_to :organization
  belongs_to :supplier
  # NULL means the whole group. A restaurant group with a Boston room and a
  # California room gets the same box from a national SKU but not from local
  # produce, so a weight is set once org-wide and split only where a city
  # actually differs.
  belongs_to :location, optional: true
  belongs_to :created_by_user, class_name: "User", optional: true

  validates :supplier_sku, :pack_size_fingerprint, presence: true
  validates :basis, inclusion: { in: BASES }
  validates :net_weight_oz, numericality: { greater_than: 0 }
  validates :supplier_sku, uniqueness: { scope: %i[organization_id location_id supplier_id] }

  scope :org_wide, -> { where(location_id: nil) }
  scope :for_location, ->(location_id) { where(location_id: location_id) }

  scope :for_supplier_sku, ->(supplier_id, sku) { where(supplier_id: supplier_id, supplier_sku: sku) }

  # Has the pack this weight describes changed underneath it?
  #
  # Compares the PARSED form when both sides parse, so a supplier rewording
  # "1 BUSHEL" as "1 BU" doesn't cry wolf — nothing about the box changed. Only
  # when one side is unparseable (the sheets case, where there is no structure
  # to compare) does it fall back to the raw string, and there a change is far
  # more likely to be real.
  #
  # The blind spot this cannot cover: a supplier who changes the physical pack
  # without changing what they call it. Nothing catches that but a chef.
  def stale_against?(current_pack_size)
    return false if current_pack_size.blank?

    was = UnitParser.parse(pack_size_fingerprint)
    now = UnitParser.parse(current_pack_size)

    if was[:parseable] && now[:parseable]
      was[:normalized_unit] != now[:normalized_unit] ||
        was[:normalized_quantity].to_f.round(4) != now[:normalized_quantity].to_f.round(4)
    else
      normalize_pack(pack_size_fingerprint) != normalize_pack(current_pack_size)
    end
  end

  # Total net weight of the pack as sold, in ounces, or nil when the basis is
  # per-piece and we cannot tell how many pieces are in the box.
  def total_oz_for(pack_size)
    return net_weight_oz.to_f if basis == "per_pack"

    count = piece_count_in(pack_size)
    return nil unless count&.positive?

    net_weight_oz.to_f * count
  end

  def self.plausible_per_lb?(price, total_oz)
    return false unless price.to_f.positive? && total_oz.to_f.positive?

    per_lb = price.to_f / (total_oz.to_f / 16.0)
    per_lb.between?(MIN_PLAUSIBLE_PER_LB, MAX_PLAUSIBLE_PER_LB)
  end

  private

  # How many pieces the box holds. A parsed count pack answers directly
  # ("24 CT" → 24); otherwise fall back to the leading number, which is what
  # carries the count in the unparseable packs this exists for ("10 SHEET").
  def piece_count_in(pack_size)
    parsed = UnitParser.parse(pack_size)
    return parsed[:normalized_quantity].to_f if parsed[:parseable] && parsed[:normalized_unit] == "each"

    lead = pack_size.to_s[/\A\s*(\d+(?:\.\d+)?)/, 1]
    lead&.to_f
  end

  def normalize_pack(str)
    str.to_s.upcase.gsub(/[^A-Z0-9.]+/, " ").strip
  end
end
