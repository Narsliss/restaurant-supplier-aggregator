class CategorizeProductsJob < ApplicationJob
  queue_as :default

  # Categorize products that don't have a category yet, or re-categorize all
  # Usage:
  #   CategorizeProductsJob.perform_later - categorize uncategorized only
  #   CategorizeProductsJob.perform_later(recategorize_all: true) - recategorize everything
  #   CategorizeProductsJob.perform_later(product_ids: [1, 2, 3]) - specific products
  def perform(options = {})
    recategorize_all = options[:recategorize_all] || false
    product_ids = options[:product_ids]
    use_ai = options.fetch(:use_ai, true)

    products = if product_ids.present?
      Product.where(id: product_ids)
    elsif recategorize_all
      Product.all
    else
      Product.where(category: [nil, ""])
    end

    total = products.count
    Rails.logger.info "[CategorizeProductsJob] Starting categorization of #{total} products (use_ai: #{use_ai})"

    categorized = 0
    failed = 0

    if use_ai && ENV["OPENAI_API_KEY"].present?
      # Batch categorize with AI for efficiency
      products.find_in_batches(batch_size: 20) do |batch|
        names = batch.map(&:name)
        results = AiProductCategorizer.categorize_batch(names)

        batch.each_with_index do |product, index|
          result = results[index]
          if result[:category].present?
            product.update(category: result[:category], subcategory: result[:subcategory])
            categorized += 1
          else
            failed += 1
          end
        end

        # Small delay to avoid rate limiting
        sleep(0.5) if batch.size == 20
      end
    else
      # Use rule-based categorization only (faster, no API calls)
      products.find_each do |product|
        result = AiProductCategorizer.rule_based_categorize(product.name)
        if result[:category].present?
          product.update(category: result[:category], subcategory: result[:subcategory])
          categorized += 1
        else
          failed += 1
        end
      end
    end

    Rails.logger.info "[CategorizeProductsJob] Completed: #{categorized} categorized, #{failed} failed out of #{total}"

    { total: total, categorized: categorized, failed: failed }
  end
end
