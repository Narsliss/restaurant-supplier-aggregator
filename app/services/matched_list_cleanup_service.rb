# Chef-driven cleanup of an exploded matched list (see the alfios incident:
# rotated USF order guides left split duplicate lines, catalog-search filled
# them with identical sibling pairings, and rejections left zero-item husks).
#
# Everything here is chef-INITIATED and chef-DECIDED:
#   - scan       -> only FLAGS lines (possible_duplicate_of_id); zero merging.
#   - merge!     -> executes ONE merge the chef explicitly clicked.
#   - purge_empty-> removes only zero-item, machine-status husk lines.
#
# Chef work is protected structurally: manual/confirmed lines are never
# flagged as duplicates (they can only be the KEEPER side of a pair), never
# purged, and nothing runs without an explicit request.
class MatchedListCleanupService
  CHEF_STATUSES = %w[manual confirmed].freeze
  MACHINE_STATUSES = %w[auto_matched unmatched rejected].freeze

  attr_reader :aggregated_list

  def initialize(aggregated_list)
    @aggregated_list = aggregated_list
  end

  # Flag machine-created lines that duplicate an earlier keeper line.
  # Identity = same supplier holding the same SupplierProduct row, or the
  # same baseline spine product (two guide generations = two SP rows, one
  # spine product). Chef-touched lines are always keepers, never flagged.
  # Lines the chef already dismissed (duplicate_dismissed_at) are skipped.
  # Returns { flagged: n, empty: n }.
  def scan
    matches = aggregated_list.product_matches
                             .includes(product_match_items: { supplier_list_item: :supplier_product })
                             .to_a

    # Keepers claim identities first: chef-touched lines, then by position.
    ordered = matches.sort_by do |pm|
      [CHEF_STATUSES.include?(pm.match_status) ? 0 : 1, pm.position || 0, pm.id]
    end

    owner_by_identity = {}
    flagged = 0

    ordered.each do |pm|
      identities = identities_for(pm)
      next if identities.empty? # zero-item husks handled by purge_empty

      owner = identities.filter_map { |key| owner_by_identity[key] }.first

      if owner.nil? || CHEF_STATUSES.include?(pm.match_status) || pm.duplicate_dismissed_at.present?
        identities.each { |key| owner_by_identity[key] ||= pm }
        # A previously flagged line whose owner disappeared stays flagged
        # only if the scan still finds an owner; otherwise clear it.
        if owner.nil? && pm.possible_duplicate_of_id.present?
          pm.update!(possible_duplicate_of_id: nil)
        end
        next
      end

      unless pm.possible_duplicate_of_id == owner.id
        pm.update!(possible_duplicate_of_id: owner.id)
      end
      flagged += 1
    end

    { flagged: flagged, empty: empty_husks.count }
  end

  # Zero-judgment auto-dedupe, safe to run unattended after every matching
  # pass: merges machine-status lines that hold the LITERALLY IDENTICAL
  # supplier products (same supplier_product row) as a sibling line — the
  # self-duplicates created when two lists from one supplier overlap (CW
  # order guide + Previously Purchased). Lines with any item the keeper
  # lacks, and all chef-touched lines, are never auto-merged — those remain
  # flag-and-ask territory. Returns the number merged.
  def auto_merge_same_product
    rows = ProductMatchItem.joins(:product_match, :supplier_list_item)
                           .where(product_matches: { aggregated_list_id: aggregated_list.id })
                           .where.not(supplier_list_items: { supplier_product_id: nil })
                           .pluck(:product_match_id, :supplier_id, 'supplier_list_items.supplier_product_id')

    dup_groups = rows.group_by { |_, sup_id, sp_id| [sup_id, sp_id] }
                     .select { |_, entries| entries.map(&:first).uniq.size > 1 }
    return 0 if dup_groups.empty?

    match_ids = dup_groups.values.flatten(1).map(&:first).uniq
    matches = aggregated_list.product_matches.where(id: match_ids)
                             .includes(product_match_items: { supplier_list_item: :supplier_product })
                             .index_by(&:id)

    merged = 0
    dup_groups.each_value do |entries|
      lines = entries.map(&:first).uniq.filter_map { |id| matches[id] }
      keeper = lines.min_by do |pm|
        [CHEF_STATUSES.include?(pm.match_status) ? 0 : 1, pm.position || 0, pm.id]
      end

      lines.each do |pm|
        next if pm.id == keeper.id
        next unless MACHINE_STATUSES.include?(pm.match_status)
        next unless ProductMatch.exists?(pm.id) && ProductMatch.exists?(keeper.id)

        keeper_keys = keeper.reload.product_match_items.includes(:supplier_list_item).filter_map do |pmi|
          sp_id = pmi.supplier_list_item&.supplier_product_id
          [pmi.supplier_id, sp_id] if sp_id
        end.to_set

        covered = pm.reload.product_match_items.includes(:supplier_list_item).all? do |pmi|
          sp_id = pmi.supplier_list_item&.supplier_product_id
          sp_id && keeper_keys.include?([pmi.supplier_id, sp_id])
        end
        next unless covered

        merge_into!(pm, keeper)
        merged += 1
      end
    end

    Rails.logger.info "[MatchedListCleanup] Auto-merged #{merged} identical-product lines" if merged.positive?
    merged
  end

  # Merge a flagged duplicate into its keeper, per the chef's click.
  # Supplier items the keeper lacks move over; redundant ones are dropped
  # (their SupplierListItems survive — only the grouping row goes away).
  def merge!(duplicate)
    target = duplicate.possible_duplicate_of
    raise ArgumentError, 'line is not flagged as a duplicate' unless target
    raise ArgumentError, 'cross-list merge' unless target.aggregated_list_id == aggregated_list.id

    merge_into!(duplicate, target)
  end

  # Shared merge mechanics: move missing-supplier items, drop redundant
  # ones, repoint stale flags, delete the duplicate line.
  def merge_into!(duplicate, target)
    ActiveRecord::Base.transaction do
      taken = target.product_match_items.pluck(:supplier_id).to_set

      duplicate.product_match_items.each do |pmi|
        if taken.include?(pmi.supplier_id)
          pmi.destroy!
        else
          pmi.update!(product_match: target, is_primary: false)
          taken << pmi.supplier_id
        end
      end

      # Anything else flagged against the vanishing line re-points to the keeper
      aggregated_list.product_matches
                     .where(possible_duplicate_of_id: duplicate.id)
                     .update_all(possible_duplicate_of_id: target.id)

      # ORDERING SAFETY: chef order-list rows and in-progress carts reference
      # match ids. The FK would silently nullify order_list_items ("Unknown
      # Product") and CurrentOrder entries would vanish from the builder —
      # repoint both to the keeper so nothing the chef built goes dark.
      OrderListItem.where(product_match_id: duplicate.id).find_each do |oli|
        already = OrderListItem.where(order_list_id: oli.order_list_id, product_match_id: target.id)
                               .where.not(id: oli.id).exists?
        # Same product already on that order list via the keeper line —
        # dropping the now-redundant row beats leaving a broken one.
        already ? oli.destroy! : oli.update!(product_match_id: target.id)
      end

      CurrentOrder.where(aggregated_list_id: aggregated_list.id).find_each do |co|
        next unless co.state.is_a?(Hash) && co.state.key?(duplicate.id.to_s)

        st = co.state.dup
        entry = st.delete(duplicate.id.to_s)
        st[target.id.to_s] ||= entry
        co.update!(state: st)
      end

      # The loaded association still contains the item we just moved to the
      # keeper — destroying through the stale cache would delete it. Reset so
      # dependent: :destroy only sees what actually still belongs to the line.
      duplicate.product_match_items.reset
      duplicate.destroy!

      if target.match_status == 'unmatched' &&
         target.product_match_items.reload.map(&:supplier_id).uniq.size > 1
        target.update!(match_status: 'auto_matched')
      end
    end

    target
  end

  # One-click sweep of the PROVABLE duplicates: flagged machine lines whose
  # every item is identity-matched (same SupplierProduct row, or same
  # supplier+spine product) to its keeper. Merging these can't lose anything
  # — the keeper already holds each item's identity. Flagged lines with any
  # item the keeper lacks stay behind for one-by-one judgment.
  # Returns the number merged.
  def bulk_merge_exact
    merged = 0
    aggregated_list.product_matches.flagged_duplicates
                   .where(match_status: MACHINE_STATUSES)
                   .includes(:possible_duplicate_of,
                             product_match_items: { supplier_list_item: :supplier_product })
                   .find_each do |dup|
      target = dup.possible_duplicate_of
      next unless target && target.aggregated_list_id == aggregated_list.id
      next unless exact_duplicate_of?(dup, target)

      merge!(dup)
      merged += 1
    end
    merged
  end

  # Chef says "not a duplicate": clear the flag and remember the dismissal
  # so future scans don't re-flag the same line.
  def dismiss!(product_match)
    product_match.update!(possible_duplicate_of_id: nil, duplicate_dismissed_at: Time.current)
  end

  # Remove zero-item husk lines (machine statuses only — an empty line the
  # chef manually confirmed, however odd, is theirs to keep).
  # Returns the number removed.
  def purge_empty
    husks = empty_husks.to_a
    ActiveRecord::Base.transaction do
      aggregated_list.product_matches
                     .where(possible_duplicate_of_id: husks.map(&:id))
                     .update_all(possible_duplicate_of_id: nil)
      husks.each(&:destroy!)
    end
    husks.size
  end

  # Zero-item machine lines — excluding any still referenced by a chef's
  # order-list row. Purging a referenced husk would FK-nullify the row into
  # an unorderable "Unknown Product" (observed: 109 rows on the alfios
  # cleanup). Referenced husks stay until their rows are gone.
  def empty_husks
    aggregated_list.product_matches
                   .where(match_status: MACHINE_STATUSES)
                   .where.missing(:product_match_items)
                   .where.not(id: OrderListItem.where.not(product_match_id: nil).select(:product_match_id))
  end

  private

  # Every item of the duplicate is already represented on the target (by SP
  # row or supplier+spine identity) — merging cannot lose information.
  def exact_duplicate_of?(dup, target)
    target_keys = identities_for(target).to_set

    dup.product_match_items.all? do |pmi|
      sp = pmi.supplier_list_item&.supplier_product
      next false unless sp

      keys = [[:sp, sp.id]]
      keys << [:spine, pmi.supplier_id, sp.product_id] if sp.product_id.present?
      keys.any? { |k| target_keys.include?(k) }
    end
  end

  # Identity keys for a line: one per supplier-product row, plus one per
  # supplier+spine-product pair when the spine link exists.
  def identities_for(product_match)
    product_match.product_match_items.flat_map do |pmi|
      sp = pmi.supplier_list_item&.supplier_product
      next [] unless sp

      keys = [[:sp, sp.id]]
      keys << [:spine, pmi.supplier_id, sp.product_id] if sp.product_id.present?
      keys
    end
  end
end
