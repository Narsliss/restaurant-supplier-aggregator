class ImportSupplierProductsService
  attr_reader :supplier, :credential, :results

  def initialize(credential)
    @credential = credential
    @supplier = credential.supplier
    @results = { imported: 0, updated: 0, skipped: 0, errors: [] }
  end

  # Import products from the supplier's catalog by searching for common food categories
  def import_catalog(search_terms: nil)
    search_terms ||= default_search_terms

    Rails.logger.info "[ImportProducts] Starting catalog import for #{supplier.name} with #{search_terms.size} search terms"

    begin
      scraper = supplier.scraper_klass.new(credential)
      catalog_items = scraper.scrape_catalog(search_terms)
    rescue Scrapers::BaseScraper::AuthenticationError => e
      credential.mark_failed!(e.message)
      results[:errors] << "Authentication failed: #{e.message}"
      return results
    rescue => e
      results[:errors] << "Scraping failed: #{e.class.name} — #{e.message}"
      Rails.logger.error "[ImportProducts] Scraping failed for #{supplier.name}: #{e.message}"
      return results
    end

    Rails.logger.info "[ImportProducts] Found #{catalog_items.size} items from #{supplier.name}"

    catalog_items.each do |item|
      import_item(item)
    end

    Rails.logger.info "[ImportProducts] #{supplier.name} import complete: #{results[:imported]} imported, #{results[:updated]} updated, #{results[:skipped]} skipped"
    results
  end

  # Import a single scraped item into the database
  def import_item(item)
    return if item[:supplier_sku].blank? || item[:supplier_name].blank?

    # Find or create the SupplierProduct
    supplier_product = SupplierProduct.find_or_initialize_by(
      supplier: supplier,
      supplier_sku: item[:supplier_sku]
    )

    if supplier_product.new_record?
      supplier_product.assign_attributes(
        supplier_name: item[:supplier_name],
        current_price: item[:current_price],
        pack_size: item[:pack_size],
        supplier_url: item[:supplier_url],
        in_stock: item[:in_stock] != false,
        price_updated_at: item[:current_price].present? ? Time.current : nil,
        last_scraped_at: Time.current
      )

      # Try to find or create a matching Product
      product = find_or_create_product(item)
      supplier_product.product = product if product

      if supplier_product.save
        results[:imported] += 1
      else
        results[:errors] << "#{item[:supplier_name]}: #{supplier_product.errors.full_messages.join(', ')}"
      end
    else
      # Update existing record with fresh data
      attrs = { last_scraped_at: Time.current, supplier_name: item[:supplier_name] }
      attrs[:pack_size] = item[:pack_size] if item[:pack_size].present?
      attrs[:supplier_url] = item[:supplier_url] if item[:supplier_url].present?

      if item[:current_price].present? && item[:current_price] != supplier_product.current_price
        attrs[:previous_price] = supplier_product.current_price
        attrs[:current_price] = item[:current_price]
        attrs[:price_updated_at] = Time.current
      end

      if item[:in_stock] != nil
        attrs[:in_stock] = item[:in_stock]
      end

      supplier_product.update!(attrs)
      results[:updated] += 1
    end
  rescue => e
    results[:errors] << "#{item[:supplier_name]}: #{e.message}"
    Rails.logger.warn "[ImportProducts] Error importing #{item[:supplier_sku]}: #{e.message}"
  end

  private

  # Try to match an existing Product by name, or create a new one.
  # Size variants (e.g. "Chicken Breast 4oz" vs "6oz") should match the same Product
  # so they appear as different listings on the same product page.
  def find_or_create_product(item)
    normalized = item[:supplier_name].downcase.gsub(/[^a-z0-9\s]/, "").squish

    # First try exact normalized match
    product = Product.where("normalized_name = ?", normalized).first
    return product if product

    # Fuzzy match: strip size/weight tokens so "Chicken Breast 4oz" matches "Chicken Breast 6oz"
    base = base_product_name(normalized)

    if base.split.size >= 2
      words = base.split
      pattern = "%" + words.join("%") + "%"
      candidates = Product.where("normalized_name ILIKE ?", pattern).to_a

      # Among candidates, verify their base name matches ours (not just a substring)
      product = candidates.find { |c| base_product_name(c.normalized_name.to_s) == base }
    end

    # Create new product if no match found
    product ||= Product.create!(
      name: item[:supplier_name],
      category: item[:category] || guess_category(item[:supplier_name]),
      unit_size: item[:pack_size]
    )

    product
  end

  # Strip size/weight/count tokens from a normalized product name to get the "base" identity.
  # This lets size variants like "Salmon 6 Oz" and "Salmon 8 Oz" match the same product.
  # Keeps words that describe the product itself (brand, variety, cut, etc.).
  def base_product_name(name)
    name
      .gsub(/\b\d+\s*(oz|lb|lbs|kg|g|gal|gallon|liter|litre|ct|count|pc|pcs|pack|pk)\b/, "") # 6 oz, 40 lb
      .gsub(/\b\d+x\d+\b/, "")       # case packs like 4x5
      .gsub(/\b\d+\s*#\b/, "")        # weight like 40#
      .squish
  end

  # Simple category guesser based on product name keywords
  def guess_category(name)
    n = name.downcase
    return "Poultry" if n.match?(/chicken|turkey|duck|poultry|wing|thigh|breast/)
    return "Meat" if n.match?(/beef|steak|pork|lamb|veal|bacon|sausage|ground|rib|loin|chop/)
    return "Seafood" if n.match?(/salmon|shrimp|fish|tuna|crab|lobster|oyster|clam|scallop|cod|tilapia|mahi/)
    return "Produce" if n.match?(/lettuce|tomato|onion|potato|carrot|pepper|garlic|herb|mushroom|avocado|lemon|lime|apple|berry|fruit|vegetable|greens|kale|spinach|celery|cucumber/)
    return "Dairy" if n.match?(/milk|cream|cheese|butter|yogurt|egg|mozzarella|parmesan|cheddar/)
    return "Bakery" if n.match?(/bread|roll|bun|tortilla|pastry|cake|cookie|muffin|croissant/)
    return "Dry Goods" if n.match?(/flour|sugar|rice|pasta|oil|vinegar|sauce|spice|salt|pepper|seasoning/)
    return "Beverages" if n.match?(/water|juice|soda|coffee|tea|wine|beer/)
    return "Frozen" if n.match?(/frozen|ice cream|sorbet/)
    nil
  end

  def default_search_terms
    %w[
      chicken beef pork salmon shrimp
      lettuce tomato onion potato
      cheese butter cream milk
      oil flour sugar rice pasta
      turkey lamb veal bacon sausage
      crab lobster tilapia cod tuna
      mushroom pepper garlic celery carrot
      broccoli squash zucchini cucumber spinach
      avocado lemon lime apple berry
      bread tortilla bun roll
      sauce vinegar ketchup mustard mayo
      coffee tea juice
      egg yogurt sour\ cream
      ice\ cream frozen
      herbs seasoning spice
    ]
  end
end
