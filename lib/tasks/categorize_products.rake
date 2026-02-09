namespace :products do
  desc "Categorize products using AI (or rules if no API key)"
  task categorize: :environment do
    use_ai = ENV["OPENAI_API_KEY"].present?
    recategorize = ENV["RECATEGORIZE"] == "true"

    puts "Starting product categorization..."
    puts "  Mode: #{use_ai ? 'AI-powered' : 'Rule-based'}"
    puts "  Scope: #{recategorize ? 'All products' : 'Uncategorized only'}"

    result = CategorizeProductsJob.perform_now(
      recategorize_all: recategorize,
      use_ai: use_ai
    )

    puts "\nResults:"
    puts "  Total processed: #{result[:total]}"
    puts "  Categorized: #{result[:categorized]}"
    puts "  Failed/Uncategorized: #{result[:failed]}"
  end

  desc "Show category distribution"
  task category_stats: :environment do
    puts "\nCategory Distribution:"
    puts "-" * 40

    stats = Product.group(:category).count.sort_by { |_, count| -count }
    total = stats.sum { |_, count| count }

    stats.each do |category, count|
      pct = (count.to_f / total * 100).round(1)
      category_name = category || "(uncategorized)"
      puts "  #{category_name.ljust(25)} #{count.to_s.rjust(6)} (#{pct}%)"
    end

    puts "-" * 40
    puts "  #{'Total'.ljust(25)} #{total.to_s.rjust(6)}"

    uncategorized = Product.where(category: [nil, ""]).count
    if uncategorized > 0
      puts "\n#{uncategorized} products need categorization. Run: rake products:categorize"
    end
  end
end
