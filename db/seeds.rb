# frozen_string_literal: true

# Seed file for Restaurant Supplier Aggregator

puts 'Seeding database...'

# Create Suppliers
puts 'Creating suppliers...'

suppliers_data = [
  {
    name: 'US Foods',
    code: 'usfoods',
    base_url: 'https://order.usfoods.com',
    login_url: 'https://order.usfoods.com',
    scraper_class: 'Scrapers::UsFoodsScraper',
    password_required: false,
    requirements: [
      { type: 'order_minimum', numeric_value: 250.00,
        error_message: 'US Foods requires a minimum order of $250.00. Your current total is ${{current_total}}. Add ${{difference}} more to proceed.' },
      { type: 'cutoff_time', error_message: 'Orders must be placed by 6:00 PM for next-day delivery.' }
    ]
  },
  {
    name: "Chef's Warehouse",
    code: 'chefswarehouse',
    base_url: 'https://www.chefswarehouse.com',
    login_url: 'https://www.chefswarehouse.com/login',
    scraper_class: 'Scrapers::ChefsWarehouseScraper',
    password_required: true,
    requirements: [
      { type: 'order_minimum', numeric_value: 200.00,
        error_message: "Chef's Warehouse requires a minimum order of $200.00. Your current total is ${{current_total}}." }
    ]
  },
  {
    name: 'What Chefs Want',
    code: 'whatchefswant',
    base_url: 'https://www.whatchefswant.com',
    login_url: 'https://www.whatchefswant.com/customer-login/',
    scraper_class: 'Scrapers::WhatChefsWantScraper',
    password_required: false,
    auth_type: 'welcome_url',
    requirements: [
      { type: 'order_minimum', numeric_value: 150.00,
        error_message: 'What Chefs Want requires a minimum order of $150.00. Your current total is ${{current_total}}.' }
    ]
  },
  {
    name: 'Premiere Produce One',
    code: 'premiereproduceone',
    base_url: 'https://premierproduceone.pepr.app',
    login_url: 'https://premierproduceone.pepr.app/',
    scraper_class: 'Scrapers::PremiereProduceOneScraper',
    password_required: false,
    requirements: [
      { type: 'order_minimum', numeric_value: 100.00,
        error_message: 'Premiere Produce One requires a minimum order of $100.00. Your current total is ${{current_total}}.' }
    ]
  }
]

suppliers_data.each do |supplier_data|
  requirements = supplier_data.delete(:requirements)
  password_required = supplier_data.delete(:password_required) { true }

  supplier = Supplier.find_or_create_by!(code: supplier_data[:code]) do |s|
    s.name = supplier_data[:name]
    s.base_url = supplier_data[:base_url]
    s.login_url = supplier_data[:login_url]
    s.scraper_class = supplier_data[:scraper_class]
    s.password_required = password_required
    s.active = true
  end

  supplier.update!(password_required: password_required) if supplier.password_required != password_required

  auth_type = password_required ? 'password' : '2FA only'
  puts "  Created supplier: #{supplier.name} (#{auth_type})"

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

# Create users for initial setup
if Rails.env.development? || Rails.env.production?
  # Check if a super admin already exists
  existing_super_admin = User.find_by(role: 'super_admin')

  # Create super admin only if one doesn't exist
  if existing_super_admin
    puts "  Super admin already exists: #{existing_super_admin.email}"
  else
    puts 'Creating super admin user...'

    admin_user = User.create!(
      email: 'carmin@las-noches.com',
      password: 'Tres-Leches16!',
      password_confirmation: 'Tres-Leches16!',
      first_name: 'Carmin',
      last_name: 'Admin',
      role: 'super_admin'
    )

    Location.find_or_create_by!(user: admin_user, name: 'Admin Office') do |l|
      l.address = '456 Admin Ave'
      l.city = 'New York'
      l.state = 'NY'
      l.zip_code = '10002'
      l.is_default = true
    end

    puts '  Created super admin user: carmin@las-noches.com'
  end
end

puts 'Seeding complete!'
