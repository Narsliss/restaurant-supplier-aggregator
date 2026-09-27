# Uses the shared product map (the blueprint: SupplierProduct#product_id groups
# every supplier's version of the same product) to add each connected
# supplier to the matched-list rows it carries.
#
# Why (Carmin, Sep 27 2026: "the blueprint is freaking useless if it isn't
# doing that"): matching only ever went one way — a new supplier's ORDER-GUIDE
# items were checked against the map. The map knows hundreds of equivalents in
# the supplier's full catalog that never reached a row unless a script was run
# by hand (the Sep 25 Performance runs). This is the other direction: for each
# row, the map's product from this supplier, added to the row.
#
# Additive only. A row gets a supplier's product when:
#   * the row isn't rejected ("Remove from list" stands),
#   * the row has nothing from that supplier yet (one per row per supplier),
#   * no chef removed that supplier from this row (MatchItemRemoval chef_edit),
#   * the map gives exactly ONE product from that supplier for the row's
#     products (ambiguity is left alone),
#   * that product is priced, not discontinued, and not already anywhere on the
#     list (including rejected rows),
#   * the supplier has a list at this restaurant mapped to the matched list
#     (i.e. it's connected here).
# Row statuses are untouched except unmatched -> auto_matched, exactly as
# catalog search does; confirmed rows stay confirmed. Silent on success.
class ProductMapFillService
  Result = Struct.new(:added, :by_supplier, :skipped, keyword_init: true)

  def initialize(aggregated_list, dry_run: false)
    @list = aggregated_list
    @dry_run = dry_run
  end

  def call
    stats = Hash.new(0)
    by_supplier = Hash.new(0)
    added = []

    supplier_lists_by_supplier.each do |supplier_id, supplier_list|
      map = products_by_map_id(supplier_id)
      next if map.empty?

      on_list = product_ids_on_list(supplier_id)
      chef_removed_rows = chef_removed_row_ids(supplier_id)

      rows.each do |row|
        next stats[:rejected_row] += 1 if row.match_status == 'rejected'
        next if row_supplier_ids(row).include?(supplier_id)
        next stats[:chef_removed] += 1 if chef_removed_rows.include?(row.id)

        candidates = row_map_ids(row).flat_map { |pid| map[pid] || [] }.uniq
        next if candidates.empty?
        next stats[:ambiguous] += 1 if candidates.size > 1

        sp = candidates.first
        next stats[:already_on_list] += 1 if on_list.include?(sp.id)

        on_list << sp.id
        by_supplier[supplier_id] += 1
        added << { row_id: row.id, supplier_product_id: sp.id }
        add!(row, supplier_list, sp) unless @dry_run
      end
    end

    supplier_lists_by_supplier.each_value(&:refresh_product_count!) if !@dry_run && added.any?
    Rails.logger.info "[ProductMapFill] List #{@list.id}: #{@dry_run ? 'would add' : 'added'} #{added.size} " \
                      "(by supplier #{by_supplier.to_h}), skipped #{stats.to_h}"
    Result.new(added: added, by_supplier: by_supplier.to_h, skipped: stats.to_h)
  end

  private

  def add!(row, supplier_list, supplier_product)
    ActiveRecord::Base.transaction do
      sli = catalog.send(:create_supplier_list_item, supplier_list, supplier_product)
      return unless sli

      row.product_match_items.create!(supplier_list_item: sli, supplier_id: supplier_product.supplier_id, is_primary: false)
      if row.match_status == 'unmatched'
        row.update!(match_status: 'auto_matched', confidence_score: [row.confidence_score || 0, 0.5].max)
      end
    end
  rescue ActiveRecord::RecordNotUnique
    nil # the row got this supplier concurrently — fine
  end

  def catalog
    @catalog ||= CatalogSearchService.new(@list)
  end

  def rows
    @rows ||= @list.product_matches
                   .includes(product_match_items: { supplier_list_item: :supplier_product })
                   .to_a
  end

  def row_supplier_ids(row)
    row.product_match_items.map(&:supplier_id)
  end

  def row_map_ids(row)
    row.product_match_items.filter_map { |pmi| pmi.supplier_list_item&.supplier_product&.product_id }.uniq
  end

  # One list per connected supplier: that supplier's list at this restaurant,
  # mapped to the matched list (lowest id when there are several).
  def supplier_lists_by_supplier
    @supplier_lists_by_supplier ||= @list.supplier_lists.order(:id).group_by(&:supplier_id).transform_values(&:first)
  end

  # { product_id => [SupplierProduct, ...] } for the supplier's usable products on the map.
  def products_by_map_id(supplier_id)
    SupplierProduct.where(supplier_id: supplier_id, discontinued: [false, nil]).where.not(product_id: nil)
                   .where('current_price > 0')
                   .group_by(&:product_id)
  end

  def product_ids_on_list(supplier_id)
    ProductMatchItem.joins(:product_match, :supplier_list_item)
                    .where(product_matches: { aggregated_list_id: @list.id }, supplier_id: supplier_id)
                    .pluck(Arel.sql('supplier_list_items.supplier_product_id')).compact.to_set
  end

  def chef_removed_row_ids(supplier_id)
    MatchItemRemoval.where(aggregated_list_id: @list.id, supplier_id: supplier_id, cause: 'chef_edit')
                    .pluck(:product_match_id).to_set
  end
end
