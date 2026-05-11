namespace :supplier_list_items do
  desc "Audit SupplierListItems whose linked SupplierProduct has a different SKU. Read-only by default; set APPLY=1 to write changes."
  task relink_by_sku: :environment do
    apply = ENV["APPLY"] == "1"
    supplier_filter = ENV["SUPPLIER"]

    suppliers = Supplier.active.order(:name)
    suppliers = suppliers.where("LOWER(name) = ?", supplier_filter.downcase) if supplier_filter.present?

    if suppliers.empty?
      puts "No matching suppliers."
      next
    end

    mode = apply ? "APPLY" : "DRY-RUN (set APPLY=1 to write)"
    puts "Mode: #{mode}"
    puts "Suppliers: #{suppliers.pluck(:name).join(', ')}"
    puts ""

    grand_relinked = 0
    grand_unfixable = 0

    suppliers.each do |supplier|
      relinked = 0
      unfixable = 0
      no_sku = 0

      relation = SupplierListItem
                   .joins(:supplier_list, :supplier_product)
                   .where(supplier_lists: { supplier_id: supplier.id })

      total = relation.count
      puts "[#{supplier.name}] linked SLIs: #{total}"

      ActiveRecord::Base.transaction do
        relation.find_each(batch_size: 200) do |sli|
          sp = sli.supplier_product
          next if sli.sku.to_s.strip == sp.supplier_sku.to_s.strip

          if sli.sku.blank?
            no_sku += 1
            next
          end

          canonical = SupplierProduct.find_by(supplier_id: supplier.id, supplier_sku: sli.sku)
          if canonical.nil?
            unfixable += 1
            puts "  [#{supplier.name}] UNFIXABLE SLI ##{sli.id} sku=#{sli.sku.inspect} name=#{sli.name.to_s.truncate(40).inspect} -> SP##{sp.id} sku=#{sp.supplier_sku.inspect} (no SP with SLI's sku exists yet)"
            next
          end

          puts "  [#{supplier.name}] RELINK SLI ##{sli.id} sku=#{sli.sku.inspect} #{sp.id} -> #{canonical.id} (#{sp.supplier_name.to_s.truncate(30)} -> #{canonical.supplier_name.to_s.truncate(30)})"
          if apply
            sli.update_columns(supplier_product_id: canonical.id)
          end
          relinked += 1
        end

        unless apply
          raise ActiveRecord::Rollback
        end
      end

      puts "[#{supplier.name}] summary: relinked=#{relinked} unfixable=#{unfixable} no_sku=#{no_sku}"
      puts ""

      grand_relinked += relinked
      grand_unfixable += unfixable
    end

    puts "=== TOTAL: relinked=#{grand_relinked} unfixable=#{grand_unfixable} (#{mode}) ==="
  end

  desc "Heal SupplierListItems whose price got stamped with a wrong-neighbor SP's value during a catalog import (sync ran before relink). Read-only by default; set APPLY=1 to write."
  task heal_corrupted_prices: :environment do
    apply = ENV["APPLY"] == "1"
    supplier_filter = ENV["SUPPLIER"]

    suppliers = Supplier.active.order(:name)
    suppliers = suppliers.where("LOWER(name) = ?", supplier_filter.downcase) if supplier_filter.present?

    if suppliers.empty?
      puts "No matching suppliers."
      next
    end

    mode = apply ? "APPLY" : "DRY-RUN (set APPLY=1 to write)"
    puts "Mode: #{mode}"
    puts "Suppliers: #{suppliers.pluck(:name).join(', ')}"
    puts ""

    grand_healed = 0

    suppliers.each do |supplier|
      healed = 0
      # Signature for sync-before-relink corruption:
      #   1. SLI is now correctly linked (sli.sku == sp.supplier_sku).
      #   2. SLI.price diverges from its canonical SP's current_price.
      #   3. SLI.previous_price matches the canonical SP's current_price —
      #      i.e. the old (correct) price is sitting in previous_price after
      #      the wrong neighbor's value got promoted into the price column.
      #   4. SLI.price matches some OTHER SP's current_price in the same
      #      supplier — that "other SP" is the wrong neighbor whose price
      #      got stamped on. Belt-and-braces guard against false positives
      #      where previous_price coincidentally equals canonical price.
      candidates = SupplierListItem
                     .joins(:supplier_list, :supplier_product)
                     .where(supplier_lists: { supplier_id: supplier.id })
                     .where("supplier_list_items.sku = supplier_products.supplier_sku")
                     .where("supplier_list_items.price IS DISTINCT FROM supplier_products.current_price")
                     .where("supplier_list_items.previous_price = supplier_products.current_price")
                     .where.not(supplier_list_items: { price: nil })

      total = candidates.count
      puts "[#{supplier.name}] corruption candidates: #{total}"

      ActiveRecord::Base.transaction do
        candidates.find_each(batch_size: 200) do |sli|
          sp = sli.supplier_product

          neighbor = SupplierProduct
                       .where(supplier_id: supplier.id, current_price: sli.price)
                       .where.not(id: sp.id)
                       .first

          if neighbor.nil?
            puts "  [#{supplier.name}] SKIP SLI ##{sli.id} sku=#{sli.sku.inspect} (price=#{sli.price} prev=#{sli.previous_price}) — no neighbor SP at that price; possible legitimate divergence"
            next
          end

          puts "  [#{supplier.name}] HEAL SLI ##{sli.id} sku=#{sli.sku.inspect} name=#{sli.name.to_s.truncate(40).inspect}: $#{sli.price} (from SP##{neighbor.id} #{neighbor.supplier_sku} '#{neighbor.supplier_name.to_s.truncate(30)}') -> $#{sp.current_price} (canonical SP##{sp.id})"

          if apply
            sli.update_columns(
              previous_price: sli.price,
              price: sp.current_price,
              price_updated_at: Time.current
            )
          end

          healed += 1
        end

        unless apply
          raise ActiveRecord::Rollback
        end
      end

      puts "[#{supplier.name}] summary: healed=#{healed}"
      puts ""

      grand_healed += healed
    end

    puts "=== TOTAL: healed=#{grand_healed} (#{mode}) ==="
  end
end
