namespace :products do
  desc "Re-normalize product names and consolidate duplicates"
  task renormalize: :environment do
    puts "Starting product renormalization..."
    puts "=" * 60

    # First pass: Update normalized_name on all products
    puts "\n1. Updating normalized names..."
    Product.find_each do |product|
      canonical = ProductNormalizer.new(product.name).canonical_name
      if canonical.present? && canonical != product.normalized_name
        product.update_column(:normalized_name, canonical)
        print "."
      end
    end
    puts " Done!"

    # Second pass: Find and merge duplicates
    puts "\n2. Finding duplicate canonical names..."
    duplicates = Product
      .group(:normalized_name)
      .having("COUNT(*) > 1")
      .count

    if duplicates.empty?
      puts "No duplicates found!"
    else
      puts "Found #{duplicates.size} groups of duplicates"

      duplicates.each do |normalized_name, count|
        products = Product.where(normalized_name: normalized_name).order(:created_at)
        primary = products.first
        others = products[1..]

        puts "\n  Merging #{count} products into: #{primary.name} (ID: #{primary.id})"
        others.each do |other|
          puts "    - #{other.name} (ID: #{other.id}, #{other.supplier_products.count} supplier products)"

          # Move supplier products to primary
          other.supplier_products.update_all(product_id: primary.id)

          # Delete the duplicate
          other.destroy
        end
      end
    end

    # Third pass: Try to match unlinked supplier products
    puts "\n3. Matching unlinked supplier products..."
    unlinked = SupplierProduct.where(product_id: nil)
    matched = 0

    unlinked.find_each do |sp|
      normalizer = ProductNormalizer.new(sp.supplier_name)
      canonical = normalizer.canonical_name
      next if canonical.blank?

      # Try exact match
      product = Product.find_by("LOWER(normalized_name) = ?", canonical.downcase)

      # Try similarity match
      unless product
        first_word = canonical.split.first
        candidates = Product.where("normalized_name ILIKE ?", "%#{first_word}%").limit(20)
        best_match = nil
        best_score = 0.0

        candidates.each do |c|
          score = ProductNormalizer.similarity(sp.supplier_name, c.name)
          if score > best_score && score >= 0.75
            best_score = score
            best_match = c
          end
        end

        product = best_match
      end

      if product
        sp.update_column(:product_id, product.id)
        matched += 1
        print "."
      end
    end

    puts " Matched #{matched} supplier products!"

    # Summary
    puts "\n" + "=" * 60
    puts "SUMMARY:"
    puts "  Products: #{Product.count}"
    puts "  Supplier Products: #{SupplierProduct.count}"
    puts "  Linked: #{SupplierProduct.where.not(product_id: nil).count}"
    puts "  Unlinked: #{SupplierProduct.where(product_id: nil).count}"

    # Show products with multiple supplier variants
    multi_supplier = Product
      .joins(:supplier_products)
      .group("products.id")
      .having("COUNT(DISTINCT supplier_products.supplier_id) > 1")
      .count

    puts "  Products with multiple suppliers: #{multi_supplier.size}"
  end

  desc "Show products available from multiple suppliers"
  task compare: :environment do
    puts "Products available from multiple suppliers:"
    puts "=" * 80

    Product
      .joins(:supplier_products)
      .group("products.id")
      .having("COUNT(DISTINCT supplier_products.supplier_id) > 1")
      .includes(supplier_products: :supplier)
      .limit(20)
      .each do |product|
        puts "\n#{product.name}"
        puts "-" * 40
        product.supplier_products.order(:current_price).each do |sp|
          price = sp.current_price ? "$#{sp.current_price}" : "N/A"
          puts "  #{sp.supplier.name.ljust(20)} #{price.ljust(10)} #{sp.pack_size}"
        end
      end
  end

  desc "Use AI (Groq) to improve product grouping"
  task ai_group: :environment do
    puts "AI Product Grouping (using Groq Llama 3)"
    puts "=" * 60

    unless ENV["GROQ_API_KEY"].present?
      puts "\nERROR: GROQ_API_KEY not set!"
      puts "Get a free API key at: https://console.groq.com/"
      puts "Then run: GROQ_API_KEY=your_key_here bin/rails products:ai_group"
      exit 1
    end

    grouper = AiProductGrouper.new

    # First, try to match unlinked supplier products
    unlinked_count = SupplierProduct.where(product_id: nil).count
    puts "\nUnlinked supplier products: #{unlinked_count}"

    if unlinked_count > 0
      print "Processing unlinked products"
      results = grouper.group_unlinked_products(limit: 100)
      puts "\n\nResults:"
      puts "  Matched to existing products: #{results[:matched]}"
      puts "  New products created: #{results[:created]}"
      puts "  Skipped: #{results[:skipped]}"
      if results[:errors].any?
        puts "  Errors: #{results[:errors].size}"
        results[:errors].first(5).each { |e| puts "    - #{e}" }
      end
    end

    # Summary
    puts "\n" + "=" * 60
    puts "SUMMARY:"
    puts "  Products: #{Product.count}"
    puts "  Supplier Products: #{SupplierProduct.count}"
    puts "  Linked: #{SupplierProduct.where.not(product_id: nil).count}"
    puts "  Unlinked: #{SupplierProduct.where(product_id: nil).count}"

    multi_supplier = SupplierProduct
      .group(:product_id)
      .having("COUNT(DISTINCT supplier_id) > 1")
      .count
    puts "  Products with multiple suppliers: #{multi_supplier.size}"
  end

  desc "Use AI to find and suggest duplicate product merges"
  task ai_find_duplicates: :environment do
    puts "AI Duplicate Detection (using Groq Llama 3)"
    puts "=" * 60

    unless ENV["GROQ_API_KEY"].present?
      puts "\nERROR: GROQ_API_KEY not set!"
      puts "Get a free API key at: https://console.groq.com/"
      exit 1
    end

    grouper = AiProductGrouper.new

    puts "\nFinding candidates and validating with AI..."
    duplicates = grouper.find_duplicate_products(limit: 30)

    if duplicates.empty?
      puts "No AI-validated duplicate products found!"
    else
      puts "\nFound #{duplicates.size} AI-validated duplicate pairs:\n"
      duplicates.each_with_index do |dupe, idx|
        p1 = dupe[:product1]
        p2 = dupe[:product2]
        puts "#{idx + 1}. (#{(dupe[:score] * 100).round}% similar)"
        puts "   Keep:   #{p1.name} (ID: #{p1.id}, #{p1.supplier_products.count} suppliers)"
        puts "   Merge:  #{p2.name} (ID: #{p2.id}, #{p2.supplier_products.count} suppliers)"
        puts ""
      end

      puts "To merge duplicates, run:"
      puts "  bin/rails products:ai_merge_duplicates"
    end
  end

  desc "Merge AI-validated duplicate products"
  task ai_merge_duplicates: :environment do
    puts "AI Duplicate Merge (using Groq Llama 3)"
    puts "=" * 60

    unless ENV["GROQ_API_KEY"].present?
      puts "\nERROR: GROQ_API_KEY not set!"
      exit 1
    end

    grouper = AiProductGrouper.new

    puts "\nFinding and validating duplicates..."
    duplicates = grouper.find_duplicate_products(limit: 50)

    if duplicates.empty?
      puts "No duplicates to merge!"
      exit 0
    end

    puts "\nFound #{duplicates.size} duplicates to merge.\n"

    merged = 0
    duplicates.each do |dupe|
      p1 = dupe[:product1]
      p2 = dupe[:product2]

      # Keep the one with more supplier products, or the older one
      if p2.supplier_products.count > p1.supplier_products.count
        primary, duplicate = p2, p1
      else
        primary, duplicate = p1, p2
      end

      print "Merging '#{duplicate.name}' into '#{primary.name}'... "
      if grouper.merge_products(primary.id, duplicate.id)
        puts "OK"
        merged += 1
      else
        puts "FAILED"
      end
    end

    puts "\n" + "=" * 60
    puts "Merged #{merged} duplicate products."
    puts "Products now: #{Product.count}"
  end

  desc "Show potential duplicate products that could be merged"
  task find_duplicates: :environment do
    puts "Scanning for potential duplicate products..."
    puts "=" * 80

    checked = Set.new
    potential_dupes = []

    Product.find_each do |product|
      next if checked.include?(product.id)

      # Find similar products
      normalizer = ProductNormalizer.new(product.name)
      base = normalizer.base_name
      next if base.blank? || base.split.size < 2

      first_word = base.split.first
      candidates = Product
        .where.not(id: product.id)
        .where("normalized_name ILIKE ?", "%#{first_word}%")
        .to_a

      candidates.each do |candidate|
        next if checked.include?(candidate.id)

        score = ProductNormalizer.similarity(product.name, candidate.name)
        if score >= 0.6 && score < 1.0
          potential_dupes << {
            product1: product,
            product2: candidate,
            score: score
          }
          checked << candidate.id
        end
      end

      checked << product.id
    end

    if potential_dupes.empty?
      puts "No potential duplicates found!"
    else
      puts "Found #{potential_dupes.size} potential duplicate pairs:\n\n"

      potential_dupes.sort_by { |d| -d[:score] }.first(30).each do |dupe|
        puts "Score: #{(dupe[:score] * 100).round(1)}%"
        puts "  1. #{dupe[:product1].name} (ID: #{dupe[:product1].id})"
        puts "  2. #{dupe[:product2].name} (ID: #{dupe[:product2].id})"
        puts ""
      end
    end
  end
end
