module Suppliers
  # Takes Sysco Marketplace / Specialty items off EnPlace: out of chefs'
  # matched lists, out of the mirrored Sysco order guides, and out of the
  # catalog (discontinued). EnPlace is for general bulk ordering; those items
  # can't be modified or cancelled once submitted, ship separately and can't
  # be returned (Carmin, Sep 27 2026 — explicitly including matched lists).
  #
  # 1. Classify: every Sysco product without a seller group is looked up by
  #    catalog search (20 SKUs a call) and its seller + group saved.
  # 2. Remove — skipped on a dry run, which only reports what would go:
  #    matched-list cells via MatchedListSupplierRemoval (the one sanctioned
  #    path: audited, empties rows no order list / cart still uses), then the
  #    guide items, teaser cells, comparison peers, and the product itself
  #    (discontinued — kept for order history).
  #
  # What keeps them gone: the catalog import searches LOCAL_SALES only, the
  # guide sync leaves third-party items out, the refresh discontinues any it
  # meets, and the cart refuses them (Scrapers::SyscoScraper).
  class SyscoMarketplaceRemoval
    CAUSE = 'supplier_item_removed'.freeze

    def initialize(credential, dry_run: true, scraper: nil)
      @credential = credential
      @supplier = credential.supplier
      @dry_run = dry_run
      @scraper = scraper || Scrapers::SyscoScraper.new(credential)
    end

    def call
      classified = classify!
      products = third_party_products
      ids = products.map { |p| p[:id] }
      skus = products.map { |p| p[:sku] }

      list_items = SupplierListItem.joins(:supplier_list)
                                   .where(supplier_lists: { supplier_id: @supplier.id })
                                   .where('supplier_list_items.supplier_product_id IN (:ids) OR supplier_list_items.sku IN (:skus)',
                                          ids: ids.presence || [0], skus: skus.presence || [''])
      match_items = ProductMatchItem.where(supplier_list_item_id: list_items.select(:id))

      report = {
        dry_run: @dry_run,
        classified: classified,
        third_party_products: ids.size,
        by_group: products.group_by { |p| p[:group] || "seller:#{p[:seller]}" }.transform_values(&:size),
        matched_list_cells: match_items.count,
        matched_rows_touched: match_items.distinct.count(:product_match_id),
        guide_items: list_items.count,
        teaser_cells: TeaserMatch.where(supplier_product_id: ids).count,
        sample: products.first(15).map { |p| "#{p[:sku]} #{p[:name].to_s.first(40)} (#{p[:group] || p[:seller]})" }
      }
      return report if @dry_run || ids.empty?

      report[:removal] = remove!(ids, list_items, match_items)
      report
    end

    private

    def classify!
      unclassified = SupplierProduct.where(supplier: @supplier, supplier_seller_group: [nil, ''])
                                    .pluck(:supplier_sku)
      return 0 if unclassified.empty?

      @scraper.send(:ensure_api_session!)
      found = @scraper.send(:discover_sellers, unclassified, limit: nil)
      Rails.logger.info "[SyscoMarketplaceRemoval] classified #{found.compact.size}/#{unclassified.size} " \
                        "(#{found.count { |_, s| s.nil? }} not found by search)"
      found.compact.size
    end

    def third_party_products
      account_seller = @scraper.send(:load_api_tokens)[:seller_id]
      SupplierProduct.where(supplier: @supplier)
                     .pluck(:id, :supplier_sku, :supplier_name, :supplier_seller_id, :supplier_seller_group)
                     .filter_map do |id, sku, name, seller, group|
        next unless @scraper.send(:third_party_seller?, seller, group, account_seller)

        { id: id, sku: sku, name: name, seller: seller, group: group }
      end
    end

    def remove!(ids, list_items, match_items)
      now = Time.current
      ActiveRecord::Base.transaction do
        cells = MatchedListSupplierRemoval.new(match_items, cause: CAUSE).call

        # A row that survives keeps a valid image choice.
        ProductMatch.where(canonical_image_supplier_product_id: ids)
                    .update_all(canonical_image_supplier_product_id: nil)
        guide_items = list_items.destroy_all.size
        teasers = TeaserMatch.where(supplier_product_id: ids).delete_all
        peers = ComparisonCandidate.where(supplier_product_id: ids)
                                   .or(ComparisonCandidate.where(candidate_supplier_product_id: ids)).delete_all
        products = SupplierProduct.where(id: ids).update_all(
          discontinued: true, discontinued_at: now, in_stock: false, updated_at: now
        )

        { **cells, guide_items: guide_items, teaser_cells: teasers, comparison_peers: peers, products_discontinued: products }
      end
    end
  end
end
