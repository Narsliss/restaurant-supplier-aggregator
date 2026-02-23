# One-shot job to backfill nil categories on Product records.
# Enqueue via: BackfillProductCategoriesJob.perform_later
class BackfillProductCategoriesJob < ApplicationJob
  queue_as :low

  def perform
    updated = 0
    skipped = 0

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

    Rails.logger.info "[BackfillProductCategories] Done: #{updated} categorized, #{skipped} skipped, #{Product.where(category: [nil, '']).count} remaining"
  end
end
