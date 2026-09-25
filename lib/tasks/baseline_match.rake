# One-time Claude baseline product matching.
#
# Links supplier products that Claude adjudicated as the same canonical product
# (db/baseline/claude_baseline_groups.json) onto the global Product spine, so
# every chef starts with cross-supplier price comparisons they can still override.
#
# SAFETY:
#   * Dry run by default — reports, writes nothing. Pass APPLY=1 to write.
#   * Only touches the global Product spine: supplier_products.product_id (+
#     provenance) and order_list_items.product_id. Chef matches (product_matches)
#     reference supplier_products directly and are never read or written.
#   * ORDERING INTEGRITY: the OrderList order builder resolves items via
#     Product#supplier_product_for. If a merge empties an item's Product, that
#     item would resolve to nil. So whenever we move a supplier product out of
#     its old Product, we repoint any OrderListItem on that old Product to the
#     canonical (which now holds that supplier product) — the builder produces
#     the identical order. Proven by spec.
#   * Every repointed product_id (supplier_products AND order_list_items) is
#     snapshotted, so `baseline:rollback` restores the exact prior state.
#   * Idempotent — re-running skips groups already applied for this run tag.
#
#   rake baseline:apply                 # dry run — prints the plan
#   rake baseline:apply APPLY=1         # writes, tagged RUN_TAG (default claude_baseline_v1)
#   rake baseline:rollback APPLY=1      # restores previous product_ids for the run tag
#   rake baseline:status                # current baseline link counts
namespace :baseline do
  GROUPS_FILE = Rails.root.join("db/baseline/claude_baseline_groups.json")

  task apply: :environment do
    run_tag = ENV.fetch("RUN_TAG", "claude_baseline_v1")
    write = ENV["APPLY"] == "1"
    groups = JSON.parse(File.read(GROUPS_FILE))

    puts "Baseline apply — run_tag=#{run_tag} — #{write ? 'WRITE' : 'DRY RUN'}"
    puts "Groups in artifact: #{groups.size}"

    stats = Hash.new(0)
    groups.each do |group|
      sp_ids = group["members"].map { |m| m["sp_id"] }
      sps = SupplierProduct.where(id: sp_ids).to_a
      # Catalog drifts between export and apply — skip anything gone, or any
      # group that no longer spans 2+ suppliers.
      if sps.size < 2 || sps.map(&:supplier_id).uniq.size < 2
        stats[:skipped_stale] += 1
        next
      end
      if BaselineLinkSnapshot.exists?(run_tag: run_tag, record_type: "SupplierProduct", record_id: sps.map(&:id))
        stats[:already_applied] += 1
        next
      end

      canonical = choose_canonical(sps)
      old_product_ids = sps.map(&:product_id).compact.uniq
      affected_pids = (old_product_ids + [canonical&.id]).compact.uniq
      ol_items = OrderListItem.where(product_id: affected_pids).to_a

      # Collision guard: order_list_items has a unique (order_list_id, product_id).
      # If a single OrderList references 2+ of this group's Products, repointing
      # them onto one canonical would violate that constraint AND change how the
      # list builds. Defer such groups rather than risk order correctness.
      if ol_items.group_by(&:order_list_id).any? { |_, items| items.size > 1 }
        stats[:skipped_order_list_conflict] += 1
        next
      end

      stats[:groups_linked] += 1
      stats[:links] += sps.size
      stats[:order_list_repoints] += ol_items.size

      next unless write

      ActiveRecord::Base.transaction do
        canonical ||= Product.create!(name: group["canonical_hint"], category: group["category"].presence)
        sps.each do |sp|
          snapshot!(run_tag, "SupplierProduct", sp.id, sp.product_id)
          sp.update_columns(product_id: canonical.id, match_source: "claude_baseline",
                            match_confidence: group["confidence"])
        end
        # Preserve OrderList builder resolution: any item on a now-changed
        # Product moves to the canonical, which holds the same supplier product.
        ol_items.each do |item|
          next if item.product_id == canonical.id
          snapshot!(run_tag, "OrderListItem", item.id, item.product_id)
          item.update_columns(product_id: canonical.id)
        end
      end
    end

    puts "\n=== #{write ? 'APPLIED' : 'WOULD APPLY'} ==="
    puts "  groups linked:        #{stats[:groups_linked]}"
    puts "  product links:        #{stats[:links]}"
    puts "  order-list repoints:  #{stats[:order_list_repoints]}"
    puts "  already applied:      #{stats[:already_applied]}"
    puts "  skipped (stale):      #{stats[:skipped_stale]}"
    puts "  skipped (OL conflict):#{stats[:skipped_order_list_conflict]}"
    puts "\nDRY RUN — pass APPLY=1 to write." unless write
  end

  task rollback: :environment do
    run_tag = ENV.fetch("RUN_TAG", "claude_baseline_v1")
    write = ENV["APPLY"] == "1"
    snaps = BaselineLinkSnapshot.where(run_tag: run_tag)
    puts "Rollback #{run_tag}: #{snaps.count} snapshot rows — #{write ? 'WRITE' : 'DRY RUN'}"
    unless write
      puts "DRY RUN — pass APPLY=1 to restore."
      next
    end
    snaps.find_each do |snap|
      klass = snap.record_type.constantize
      rec = klass.find_by(id: snap.record_id)
      next unless rec
      if snap.record_type == "SupplierProduct"
        rec.update_columns(product_id: snap.previous_product_id, match_source: nil, match_confidence: nil)
      else
        rec.update_columns(product_id: snap.previous_product_id)
      end
    end
    snaps.delete_all
    puts "Restored and cleared snapshots."
  end

  task status: :environment do
    puts "claude_baseline links: #{SupplierProduct.where(match_source: 'claude_baseline').count}"
    puts "  by confidence: #{SupplierProduct.where(match_source: 'claude_baseline').group(:match_confidence).count}"
    puts "snapshot rows by tag: #{BaselineLinkSnapshot.group(:run_tag).count}"
    puts "  by record type: #{BaselineLinkSnapshot.group(:record_type).count}"
  end

  # Attach a NEW supplier's products to the existing spine, from a Claude sweep
  # of that supplier against everyone else (e.g. Performance joining after the
  # original baseline). Artifact rows are keyed by supplier CODE + SKU, not
  # database id, so the same file applies to any environment:
  #   [{ "sku": "543638", "target": { "supplier": "usfoods", "sku": "1234567" },
  #      "confidence": "high", "reason": "..." }]
  #
  # SAFETY (narrower than baseline:apply):
  #   * Only the new supplier's product moves — onto the target's existing
  #     Product. The target product and every other supplier product are never
  #     written. Chef matches (product_matches) are never read or written.
  #   * One product per supplier per canonical (Product#supplier_product_for
  #     returns the first match, so two would be ambiguous) — later rows that
  #     would add a second are skipped.
  #   * Deferred if the product's CURRENT Product is referenced by any
  #     OrderListItem, so no existing order list changes how it builds.
  #   * Snapshotted under RUN_TAG; `baseline:rollback RUN_TAG=... APPLY=1` restores.
  #
  #   rake baseline:attach SUPPLIER=performance FILE=db/baseline/performance_baseline_matches.json
  #   rake baseline:attach SUPPLIER=performance APPLY=1 RUN_TAG=claude_baseline_performance_v1
  task attach: :environment do
    code = ENV.fetch("SUPPLIER")
    run_tag = ENV.fetch("RUN_TAG", "claude_baseline_#{code}_v1")
    write = ENV["APPLY"] == "1"
    file = ENV.fetch("FILE", Rails.root.join("db/baseline/#{code}_baseline_matches.json").to_s)
    supplier = Supplier.find_by!(code: code)
    rows = JSON.parse(File.read(file))

    puts "Baseline attach — #{supplier.name} — run_tag=#{run_tag} — #{write ? 'WRITE' : 'DRY RUN'}"
    puts "Rows in artifact: #{rows.size}"

    stats = Hash.new(0)
    claimed = {} # canonical product_id => sku claimed in this run
    rows.each do |row|
      sp = SupplierProduct.find_by(supplier_id: supplier.id, supplier_sku: row["sku"])
      target = SupplierProduct.joins(:supplier)
                              .find_by(suppliers: { code: row.dig("target", "supplier") },
                                       supplier_sku: row.dig("target", "sku"))
      if sp.nil? || target.nil? || target.product_id.nil?
        stats[:skipped_stale] += 1
        next
      end
      canonical_id = target.product_id

      if BaselineLinkSnapshot.exists?(run_tag: run_tag, record_type: "SupplierProduct", record_id: sp.id) ||
         (sp.product_id == canonical_id && sp.match_source == "claude_baseline")
        stats[:already_applied] += 1
        next
      end
      if claimed.key?(canonical_id) ||
         SupplierProduct.where(product_id: canonical_id, supplier_id: supplier.id).where.not(id: sp.id).exists?
        stats[:skipped_supplier_already_on_canonical] += 1
        next
      end
      if sp.product_id && sp.product_id != canonical_id && OrderListItem.exists?(product_id: sp.product_id)
        stats[:skipped_order_list_ref] += 1
        next
      end

      claimed[canonical_id] = row["sku"]
      stats[:attached] += 1
      stats[:"into_#{target.match_source == 'claude_baseline' ? 'baseline_group' : 'plain_spine_product'}"] += 1
      next unless write

      ActiveRecord::Base.transaction do
        snapshot!(run_tag, "SupplierProduct", sp.id, sp.product_id)
        sp.update_columns(product_id: canonical_id, match_source: "claude_baseline",
                          match_confidence: row["confidence"])
      end
    end

    puts "\n=== #{write ? 'ATTACHED' : 'WOULD ATTACH'} ==="
    stats.sort.each { |k, v| puts "  #{k}: #{v}" }
    puts "\nDRY RUN — pass APPLY=1 to write." unless write
  end

  # Canonical = the Product the most members already point at (preserve history
  # and existing OrderList references); nil means "create a fresh Product".
  def choose_canonical(sps)
    pids = sps.map(&:product_id).compact
    return nil if pids.empty?
    winner_id = pids.group_by(&:itself).max_by { |_, v| v.size }.first
    Product.find_by(id: winner_id)
  end

  def snapshot!(run_tag, record_type, record_id, previous_product_id)
    BaselineLinkSnapshot.find_or_create_by!(run_tag: run_tag, record_type: record_type, record_id: record_id) do |snap|
      snap.previous_product_id = previous_product_id
    end
  end
end
