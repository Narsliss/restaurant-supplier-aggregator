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

  # Score above which we stop scanning a supplier's catalog for a given anchor
  # — it's already a very strong match, additional candidates won't displace it.
  EARLY_EXIT_SCORE = 0.85

  # Cap on per-anchor candidates we fully evaluate. Built from the inverted
  # word index and ranked by raw word overlap, so we look at the top-N
  # syntactically promising candidates and skip the long tail. 50 is a balance
  # between recall (real matches almost always cluster at the top) and the
  # per-anchor compute budget on Sysco-scale catalogs (~26K products).
  CANDIDATE_CAP = 50

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
        catalog = catalog_index[sid]
        next if catalog.nil? || catalog[:entries].empty?

        match = find_catalog_match(anchor_item, catalog)
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
  # For each supplier, build TWO things:
  #   - :entries — list of { sp:, normalized:, word_set: } (also used for canonical/exact passes)
  #   - :by_word — inverted index { word => [entry, ...] } for O(anchor_words × avg_postings)
  #     candidate gathering. Without this, the per-anchor pre-filter has to
  #     scan all 26K Sysco products; with it, we visit ~300 promising candidates.
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

      by_word = Hash.new { |h, k| h[k] = [] }
      entries.each do |entry|
        entry[:word_set].each { |word| by_word[word] << entry }
      end

      index[sid] = { entries: entries, by_word: by_word }
    end
    index
  end

  # 3-pass match against catalog entries for one anchor item (no AI pass).
  # Returns [SupplierProduct, confidence] or nil.
  def find_catalog_match(anchor_item, catalog)
    entries = catalog[:entries]
    by_word = catalog[:by_word]

    anchor_normalized = ProductNormalizer.normalize(anchor_item.name)
    anchor_word_set = anchor_normalized.downcase.split.to_set
    return nil if anchor_word_set.empty?

    # Pass 1: shared canonical Product link
    if anchor_item.supplier_product&.product_id
      entry = entries.find { |e| e[:sp].product_id == anchor_item.supplier_product.product_id }
      return [entry[:sp], 0.95] if entry
    end

    # Pass 2: exact normalized name match
    if anchor_normalized.present?
      entry = entries.find { |e| e[:normalized].present? && e[:normalized] == anchor_normalized }
      return [entry[:sp], 0.90] if entry
    end

    # Pass 3: best similarity, but only against top-CANDIDATE_CAP candidates
    # gathered via inverted-index lookup and ranked by raw word overlap.
    candidates = gather_top_candidates(anchor_word_set, by_word)
    return nil if candidates.empty?

    best_entry = nil
    best_score = 0
    anchor_size = anchor_word_set.size

    candidates.each do |entry, intersection_size|
      # Pure set ops on pre-computed word_sets — NO ProductNormalizer.new() calls,
      # which is what made the original loop 100× slower per comparison.
      set2 = entry[:word_set]
      union_size = anchor_size + set2.size - intersection_size
      next if union_size.zero?

      jaccard = intersection_size.to_f / union_size
      min_size = [anchor_size, set2.size].min
      score = if intersection_size >= 2 && min_size >= 2
                [jaccard, (intersection_size.to_f / min_size) * 0.85].max
              else
                jaccard
              end

      if score > best_score
        best_score = score
        best_entry = entry
        break if best_score >= EARLY_EXIT_SCORE
      end
    end

    return [best_entry[:sp], best_score] if best_entry && best_score >= TEASER_SIMILARITY_THRESHOLD

    nil
  end

  # Gather candidates by walking the inverted index for each anchor word, then
  # rank by word overlap and take the top CANDIDATE_CAP. The full-catalog
  # pre-filter scan is replaced with O(anchor_words × postings_per_word) work.
  # Returns [[entry, overlap_size], ...] sorted desc by overlap.
  def gather_top_candidates(anchor_word_set, by_word)
    overlap_count = Hash.new(0)
    anchor_word_set.each do |word|
      postings = by_word[word]
      next if postings.empty?

      postings.each { |entry| overlap_count[entry] += 1 }
    end

    return [] if overlap_count.empty?

    overlap_count.sort_by { |_entry, count| -count }.first(CANDIDATE_CAP)
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
