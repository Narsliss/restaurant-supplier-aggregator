# A cross-supplier alternative found automatically for a product a chef buys.
#
# Deliberately separate from ProductMatch. A chef's matched list is theirs and
# nothing here writes to it. These rows exist only to give the savings
# calculation something to compare against on the spend that has no curated
# peer — roughly 86% of it — and they can be rebuilt or dropped at any time
# without touching curation.
#
# Candidates are advisory. Orders::SavingsCalculator still applies its own pack
# band and spread gates, so a wrong candidate produces no dollar claim rather
# than a wrong one.
class ComparisonCandidate < ApplicationRecord
  SOURCES = %w[auto_basket].freeze

  belongs_to :supplier_product
  belongs_to :candidate_supplier_product, class_name: "SupplierProduct"

  validates :similarity, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :source, inclusion: { in: SOURCES }
  validate :must_cross_suppliers

  scope :confident, ->(min) { where(similarity: min..) }

  # Peers for a batch of supplier products, in one pass.
  #
  # Returns { supplier_product_id => [SupplierProduct, ...] } combining the
  # global Product spine (what curation and the baseline produced) with these
  # automatic candidates. Loaded together because the savings report walks
  # hundreds of order lines and must not issue a query per line.
  def self.peers_for(supplier_products)
    products = Array(supplier_products).compact.uniq(&:id)
    return {} if products.empty?

    spine = spine_peers_for(products)
    curated = curated_peers_for(products)
    auto = auto_peers_for(products)

    products.each_with_object({}) do |sp, acc|
      combined = (spine[sp.product_id] || []) + (curated[sp.id] || []) + (auto[sp.id] || [])
      acc[sp.id] = combined
                   .uniq(&:id)
                   .reject { |p| p.id == sp.id || p.supplier_id == sp.supplier_id }
                   .reject { |p| p.discontinued? || p.current_price.nil? }
    end
  end

  # Peers a chef put together themselves, on their own matched list.
  #
  # This is the most authoritative source there is and it was missing: the
  # calculator read the Product spine and these automatic candidates, while
  # 885 of Alfios 905 cross-supplier pairings live only in ProductMatch and
  # were invisible to it. Rejected matches are excluded — the chef said no.
  def self.curated_peers_for(products)
    ids = products.map(&:id)
    anchors = ProductMatchItem
              .joins(:supplier_list_item, :product_match)
              .where(supplier_list_items: { supplier_product_id: ids })
              .where.not(product_matches: { match_status: "rejected" })
              .pluck(:product_match_id, Arel.sql("supplier_list_items.supplier_product_id"))
    return {} if anchors.empty?

    siblings = ProductMatchItem
               .where(product_match_id: anchors.map(&:first).uniq)
               .includes(supplier_list_item: :supplier_product)
               .group_by(&:product_match_id)

    anchors.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(match_id, sp_id), acc|
      (siblings[match_id] || []).each do |item|
        peer = item.supplier_list_item&.supplier_product
        acc[sp_id] << peer if peer && peer.id != sp_id
      end
    end
  end
  private_class_method :curated_peers_for

  def self.spine_peers_for(products)
    product_ids = products.filter_map(&:product_id).uniq
    return {} if product_ids.empty?

    SupplierProduct.where(product_id: product_ids, discontinued: false)
                   .where.not(current_price: nil)
                   .to_a
                   .group_by(&:product_id)
  end
  private_class_method :spine_peers_for

  def self.auto_peers_for(products)
    rows = where(supplier_product_id: products.map(&:id))
             .includes(:candidate_supplier_product)
             .to_a
    rows.reject! { |r| r.candidate_supplier_product.nil? }
    rows.reject! { |r| r.candidate_supplier_product.discontinued? }
    rows.reject! { |r| r.candidate_supplier_product.current_price.nil? }
    rows.group_by(&:supplier_product_id)
        .transform_values { |rs| rs.map(&:candidate_supplier_product) }
  end
  private_class_method :auto_peers_for

  private

  def must_cross_suppliers
    return if supplier_product.nil? || candidate_supplier_product.nil?
    return unless supplier_product.supplier_id == candidate_supplier_product.supplier_id

    errors.add(:candidate_supplier_product, "must come from a different supplier")
  end
end
