# Builds advisory "teaser" cells for suppliers the chef does NOT have credentials
# with. For each ProductMatch in an AggregatedList, searches each unconnected
# supplier's catalog for a similar product and persists the result to the
# teaser_matches table. The show view reads from that table to populate the
# extra columns to the right of the chef's real supplier columns.
#
# CRITICAL: TeaserMatches are read-only display data. They never become
# SupplierListItems, never enter OrderPlacementService, and the user cannot
# order from them. They exist purely to give chefs a comparison reference
# for suppliers they aren't yet credentialed with.
#
# Matching strategy mirrors CatalogSearchService passes 1-3 (canonical Product
# link, exact normalized name, similarity ≥ threshold). The Groq AI pass is
# intentionally skipped — teasers are advisory, the cost/latency isn't worth
# it, and a false-positive teaser is more misleading than a missing cell.
#
# Idempotent: re-running for the same AggregatedList replaces its teasers
# atomically (delete-then-insert in a transaction).
#
# Usage:
#   service = TeaserCatalogSearchService.new(aggregated_list)
#   result = service.call
#   # => { found: 42, searched: 200, unconnected_suppliers: 3, errors: [] }
#
class TeaserCatalogSearchService
  # Higher threshold than CatalogSearchService (0.55) — teasers face a larger
  # candidate pool (full catalog of every unconnected supplier) and a false
  # positive in a non-orderable cell is purely confusing, not actionable.
  TEASER_SIMILARITY_THRESHOLD = 0.60

  attr_reader :aggregated_list, :results

  def initialize(aggregated_list)
    @aggregated_list = aggregated_list
    @results = { found: 0, searched: 0, unconnected_suppliers: 0, errors: [] }
  end

  def call
    unconnected_supplier_ids = compute_unconnected_supplier_ids
    results[:unconnected_suppliers] = unconnected_supplier_ids.size

    if unconnected_supplier_ids.empty?
      replace_teasers!([])
      return results
    end

    product_matches = aggregated_list.product_matches
                                     .where.not(match_status: 'rejected')
                                     .includes(product_match_items: { supplier_list_item: :supplier_product })
                                     .to_a
    return results if product_matches.empty?

    Rails.logger.info "[TeaserCatalogSearch] List #{aggregated_list.id}: indexing catalogs for " \
                      "#{unconnected_supplier_ids.size} unconnected suppliers..."
    catalog_index = build_catalog_index(unconnected_supplier_ids)

    teaser_rows = []
    product_matches.each do |pm|
      results[:searched] += 1
      anchor_item = pm.product_match_items.first&.supplier_list_item
      next unless anchor_item

      unconnected_supplier_ids.each do |sid|
        entries = catalog_index[sid] || []
        next if entries.empty?

        match = find_catalog_match(anchor_item, entries)
        next unless match

        sp, confidence = match
        teaser_rows << {
          aggregated_list_id: aggregated_list.id,
          product_match_id: pm.id,
          supplier_id: sid,
          supplier_product_id: sp.id,
          confidence_score: confidence.round(2),
          created_at: Time.current,
          updated_at: Time.current
        }
        results[:found] += 1
      end
    rescue StandardError => e
      results[:errors] << "match=#{pm.id}: #{e.class}: #{e.message.to_s.truncate(200)}"
      Rails.logger.error "[TeaserCatalogSearch] match=#{pm.id} failed: #{e.class}: #{e.message}"
    end

    replace_teasers!(teaser_rows)
    Rails.logger.info "[TeaserCatalogSearch] Complete: #{results}"
    results
  rescue StandardError => e
    Rails.logger.error "[TeaserCatalogSearch] Fatal: #{e.class}: #{e.message}"
    results[:errors] << "#{e.class}: #{e.message}"
    results
  end

  private

  # Suppliers that are (a) active, (b) NOT credentialed at this list's location,
  # and (c) NOT mapped via a supplier_list on this AggregatedList. These are
  # exactly the columns the show view labels "Discover" / teaser columns.
  def compute_unconnected_supplier_ids
    list_supplier_ids = aggregated_list.supplier_lists.pluck(:supplier_id).uniq

    credentialed_supplier_ids = if aggregated_list.location_id.present?
                                  SupplierCredential.where(
                                    organization_id: aggregated_list.organization_id,
                                    location_id: aggregated_list.location_id
                                  ).pluck(:supplier_id).uniq
                                else
                                  []
                                end

    connected = (list_supplier_ids + credentialed_supplier_ids).uniq
    Supplier.where(active: true).where.not(id: connected).pluck(:id)
  end

  # Pre-normalize all non-discontinued catalog products grouped by supplier.
  # Identical structure to CatalogSearchService#build_catalog_index — the
  # word_set pre-filter eliminates ~95% of comparisons.
  def build_catalog_index(supplier_ids)
    index = {}
    supplier_ids.each do |sid|
      products = SupplierProduct.where(supplier_id: sid, discontinued: false)
                                .select(:id, :supplier_id, :supplier_sku, :supplier_name,
                                        :current_price, :pack_size, :in_stock, :product_id)
      entries = products.map do |sp|
        normalized = ProductNormalizer.normalize(sp.supplier_name)
        {
          sp: sp,
          normalized: normalized,
          word_set: normalized.downcase.split.to_set
        }
      end
      index[sid] = entries
    end
    index
  end

  # 3-pass match against catalog entries for one anchor item (no AI pass).
  # Returns [SupplierProduct, confidence] or nil.
  def find_catalog_match(anchor_item, catalog_entries)
    anchor_normalized = ProductNormalizer.normalize(anchor_item.name)
    anchor_word_set = anchor_normalized.downcase.split.to_set
    return nil if anchor_word_set.empty?

    # Pass 1: shared canonical Product link
    if anchor_item.supplier_product&.product_id
      entry = catalog_entries.find { |e| e[:sp].product_id == anchor_item.supplier_product.product_id }
      return [entry[:sp], 0.95] if entry
    end

    # Pass 2: exact normalized name match
    if anchor_normalized.present?
      entry = catalog_entries.find { |e| e[:normalized].present? && e[:normalized] == anchor_normalized }
      return [entry[:sp], 0.90] if entry
    end

    # Pass 3: best similarity with word-set pre-filter
    best_entry = nil
    best_score = 0
    catalog_entries.each do |entry|
      next if (anchor_word_set & entry[:word_set]).empty?

      score = ProductNormalizer.best_similarity(anchor_item.name, entry[:sp].supplier_name)
      if score > best_score
        best_score = score
        best_entry = entry
      end
    end

    return [best_entry[:sp], best_score] if best_entry && best_score >= TEASER_SIMILARITY_THRESHOLD

    nil
  end

  # Atomically replace this list's teasers. Wrap in a transaction so a failed
  # insert can't leave the list with a partial set (which the show view would
  # then display as "fewer teasers than before").
  def replace_teasers!(rows)
    TeaserMatch.transaction do
      TeaserMatch.where(aggregated_list_id: aggregated_list.id).delete_all
      TeaserMatch.insert_all(rows) if rows.any?
    end
  end
end
