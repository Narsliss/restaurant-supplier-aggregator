namespace :products do
  desc "Backfill nil categories on Product records using rule-based AI categorizer"
  task backfill_categories: :environment do
    updated = 0
    skipped = 0
    total = Product.where(category: [nil, ""]).count
    puts "Found #{total} uncategorized products. Starting backfill..."

    Product.where(category: [nil, ""]).find_each do |product|
      sp = product.supplier_products.first
      next(skipped += 1) unless sp

      result = AiProductCategorizer.rule_based_categorize(sp.supplier_name)

      if result[:category].present? && result[:confidence] >= 0.7
        product.update!(category: result[:category], subcategory: result[:subcategory])
        updated += 1
      else
        skipped += 1
      end
    end

    puts "Backfill complete: #{updated} categorized, #{skipped} skipped"
    puts "Remaining uncategorized: #{Product.where(category: [nil, '']).count}"
  end
end
