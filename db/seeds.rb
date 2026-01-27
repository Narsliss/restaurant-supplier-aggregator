# Seed file for Restaurant Supplier Aggregator

puts "Seeding database..."

# Create Suppliers
puts "Creating suppliers..."

suppliers_data = [
  {
    name: "US Foods",
    code: "usfoods",
    base_url: "https://www.usfoods.com",
    login_url: "https://www.usfoods.com/sign-in",
    scraper_class: "Scrapers::UsFoodsScraper",
    requirements: [
      { type: "order_minimum", numeric_value: 250.00, error_message: "US Foods requires a minimum order of $250.00. Your current total is ${{current_total}}. Add ${{difference}} more to proceed." },
      { type: "cutoff_time", error_message: "Orders must be placed by 6:00 PM for next-day delivery." }
    ]
  },
  {
    name: "Chef's Warehouse",
    code: "chefswarehouse",
    base_url: "https://www.chefswarehouse.com",
    login_url: "https://www.chefswarehouse.com/login",
    scraper_class: "Scrapers::ChefsWarehouseScraper",
    requirements: [
      { type: "order_minimum", numeric_value: 200.00, error_message: "Chef's Warehouse requires a minimum order of $200.00. Your current total is ${{current_total}}." }
    ]
  },
  {
    name: "What Chefs Want",
    code: "whatchefswant",
    base_url: "https://www.whatchefswant.com",
    login_url: "https://www.whatchefswant.com/login",
    scraper_class: "Scrapers::WhatChefsWantScraper",
    requirements: [
      { type: "order_minimum", numeric_value: 150.00, error_message: "What Chefs Want requires a minimum order of $150.00. Your current total is ${{current_total}}." }
    ]
  }
]

suppliers_data.each do |supplier_data|
  requirements = supplier_data.delete(:requirements)
  
  supplier = Supplier.find_or_create_by!(code: supplier_data[:code]) do |s|
    s.name = supplier_data[:name]
    s.base_url = supplier_data[:base_url]
    s.login_url = supplier_data[:login_url]
    s.scraper_class = supplier_data[:scraper_class]
    s.active = true
  end

  puts "  Created supplier: #{supplier.name}"

  # Create requirements
  requirements&.each do |req|
    SupplierRequirement.find_or_create_by!(
      supplier: supplier,
      requirement_type: req[:type]
    ) do |r|
      r.numeric_value = req[:numeric_value]
      r.error_message = req[:error_message]
      r.is_blocking = true
      r.active = true
    end
  end
end

# Create sample products (for development/testing)
if Rails.env.development?
  puts "Creating sample products..."

  products_data = [
    { name: "Chicken Breast, Boneless Skinless", category: "Poultry", unit_size: "10 lb case" },
    { name: "Ground Beef 80/20", category: "Meat", unit_size: "10 lb case" },
    { name: "Atlantic Salmon Fillet", category: "Seafood", unit_size: "5 lb case" },
    { name: "Russet Potatoes", category: "Produce", unit_size: "50 lb bag" },
    { name: "Yellow Onions", category: "Produce", unit_size: "25 lb bag" },
    { name: "Roma Tomatoes", category: "Produce", unit_size: "25 lb case" },
    { name: "Mixed Greens", category: "Produce", unit_size: "3 lb case" },
    { name: "Heavy Cream", category: "Dairy", unit_size: "1 gallon" },
    { name: "Butter, Unsalted", category: "Dairy", unit_size: "36 lb case" },
    { name: "Parmesan Cheese, Shredded", category: "Dairy", unit_size: "5 lb bag" },
    { name: "Olive Oil, Extra Virgin", category: "Pantry", unit_size: "1 gallon" },
    { name: "All-Purpose Flour", category: "Pantry", unit_size: "50 lb bag" },
    { name: "Granulated Sugar", category: "Pantry", unit_size: "50 lb bag" },
    { name: "Kosher Salt", category: "Pantry", unit_size: "3 lb box" },
    { name: "Black Pepper, Ground", category: "Pantry", unit_size: "1 lb can" }
  ]

  products_data.each do |product_data|
    product = Product.find_or_create_by!(name: product_data[:name]) do |p|
      p.category = product_data[:category]
      p.unit_size = product_data[:unit_size]
    end

    # Create supplier products with sample prices
    Supplier.find_each do |supplier|
      base_price = rand(15.0..75.0).round(2)
      variation = rand(-5.0..5.0).round(2)

      SupplierProduct.find_or_create_by!(
        supplier: supplier,
        supplier_sku: "#{supplier.code.upcase}-#{product.id.to_s.rjust(5, '0')}"
      ) do |sp|
        sp.product = product
        sp.supplier_name = product.name
        sp.current_price = (base_price + variation).round(2)
        sp.in_stock = rand > 0.1 # 90% in stock
        sp.price_updated_at = Time.current
        sp.last_scraped_at = Time.current
      end
    end

    puts "  Created product: #{product.name}"
  end

  # Create a demo user
  puts "Creating demo user..."
  
  demo_user = User.find_or_create_by!(email: "demo@example.com") do |u|
    u.password = "password123"
    u.password_confirmation = "password123"
    u.first_name = "Demo"
    u.last_name = "User"
    u.role = "user"
  end

  # Create a location for demo user
  Location.find_or_create_by!(user: demo_user, name: "Main Restaurant") do |l|
    l.address = "123 Main Street"
    l.city = "New York"
    l.state = "NY"
    l.zip_code = "10001"
    l.is_default = true
  end

  puts "  Created demo user: demo@example.com (password: password123)"

  # Create an admin user
  puts "Creating admin user..."
  
  admin_user = User.find_or_create_by!(email: "admin@example.com") do |u|
    u.password = "admin123"
    u.password_confirmation = "admin123"
    u.first_name = "Admin"
    u.last_name = "User"
    u.role = "admin"
  end

  Location.find_or_create_by!(user: admin_user, name: "Admin Office") do |l|
    l.address = "456 Admin Ave"
    l.city = "New York"
    l.state = "NY"
    l.zip_code = "10002"
    l.is_default = true
  end

  puts "  Created admin user: admin@example.com (password: admin123)"
end

puts "Seeding complete!"
