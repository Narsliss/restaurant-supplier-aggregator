module Catalog
  # Finds cross-supplier alternatives for the products an organization actually
  # buys, so the savings calculation has something to compare against.
  #
  # WHY THE BASKET AND NOT THE CATALOG
  #
  # The Claude baseline sweep adjudicated 2,403 products selected by
  # catalog-wide blocking. Of the 203 distinct products Alfios orders, 8 appear
  # in it and none gained a cross-supplier peer — it matched the catalog, not
  # the basket, and those turn out to be near-disjoint sets. A chef's basket is
  # small (a couple of hundred products), stable month to month, and is the only
  # part of the catalog where a match is worth anything.
  #
  # Candidates are advisory. Orders::SavingsCalculator still applies its pack
  # band and spread gates, so a wrong candidate yields no claim rather than a
  # wrong one. Nothing here writes to ProductMatch — a chef's curation is not
  # ours to touch.
  class BasketCandidateMatcher
    MIN_SIMILARITY = 0.72

    # Two shared words before scoring. Without it this is 200 x 58,000 string
    # comparisons; with it, most candidates never reach the scorer.
    MIN_SHARED_WORDS = 2

    Result = Struct.new(:products_examined, :products_matched, :candidates_written, keyword_init: true)

    def initialize(organization, min_similarity: MIN_SIMILARITY)
      @organization = organization
      @min_similarity = min_similarity
    end

    def call
      basket = basket_products
      return Result.new(products_examined: 0, products_matched: 0, candidates_written: 0) if basket.empty?

      index = catalog_index(basket)
      matched = 0
      written = 0

      basket.each do |product|
        best = best_candidate_per_supplier(product, index)
        next if best.empty?

        matched += 1
        written += persist(product, best)
      end

      Result.new(products_examined: basket.size, products_matched: matched, candidates_written: written)
    end

    private

    attr_reader :organization, :min_similarity

    # Distinct supplier products this org has actually ordered.
    def basket_products
      ids = OrderItem.joins(:order)
                     .where(orders: { organization_id: organization.id })
                     .where.not(supplier_product_id: nil)
                     .distinct
                     .pluck(:supplier_product_id)
      return [] if ids.empty?

      SupplierProduct.where(id: ids, discontinued: false).where.not(current_price: nil).to_a
    end

    # Everything sellable that is NOT from a supplier already in the basket
    # product's own line, pre-tokenized once.
    def catalog_index(_basket)
      entries = []

      SupplierProduct.where(discontinued: false)
                     .where.not(current_price: nil)
                     .select(:id, :supplier_id, :supplier_name, :pack_size, :price_unit, :current_price, :product_id)
                     .find_each do |candidate|
        normalized = ProductNormalizer.normalize(candidate.supplier_name)
        next if normalized.blank?

        entries << [candidate, normalized.downcase.split.to_set]
      end

      entries
    end

    def best_candidate_per_supplier(product, index)
      normalized = ProductNormalizer.normalize(product.supplier_name)
      return {} if normalized.blank?

      words = normalized.downcase.split.to_set
      return {} if words.empty?

      best = {}
      index.each do |candidate, candidate_words|
        next if candidate.supplier_id == product.supplier_id
        next if (words & candidate_words).size < MIN_SHARED_WORDS
        # A shared unit basis is a precondition for any comparison at all.
        next unless candidate.normalized_unit == product.normalized_unit

        score = ProductNormalizer.best_similarity(product.supplier_name, candidate.supplier_name)
        next if score < min_similarity

        current = best[candidate.supplier_id]
        best[candidate.supplier_id] = [candidate, score] if current.nil? || score > current[1]
      end
      best
    end

    def persist(product, best_by_supplier)
      rows = best_by_supplier.values.map do |candidate, score|
        {
          supplier_product_id: product.id,
          candidate_supplier_product_id: candidate.id,
          similarity: score.round(4),
          source: "auto_basket",
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      return 0 if rows.empty?

      ComparisonCandidate.upsert_all(
        rows,
        unique_by: %i[supplier_product_id candidate_supplier_product_id],
        update_only: %i[similarity updated_at]
      )
      rows.size
    end
  end
end
