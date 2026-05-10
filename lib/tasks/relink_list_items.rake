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
end
